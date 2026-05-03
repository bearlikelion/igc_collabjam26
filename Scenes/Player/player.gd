class_name Player
extends SUCC

# Auto-runner. The level script drives position directly via parametric movement
# along path segments. Lane = perpendicular offset; forward = distance along segment.
# Player.gd handles lane input, speed, and camera pitch.

const LANE_COUNT: int = 3
const START_LANE: int = LANE_COUNT / 2

signal lane_changed
signal subway_shuffle_failed
signal subway_shuffle_completed(direction: int)
signal goal_reached

@export var start_speed: float = 2.0
@export var max_speed: float = 6.0
## Time in seconds to accelerate from start_speed to max_speed.
@export var acceleration_time: float = 5.0
@export var player_model: CharacterVisual

@export_group("Headbob")
@export var enable_headbob: bool = true
@export_range(0.0, 0.2, 0.001, "suffix:m") var headbob_amplitude: float = 0.025
@export_range(0.0, 6.0, 0.05, "suffix:steps/m") var headbob_steps_per_meter: float = 0.65
@export_range(0.0, 30.0, 0.1) var headbob_smoothing: float = 12.0

@export_group("Subway Shuffle")
@export var shuffle_choice_time: float = 0.5
@export var shuffle_recovery_time: float = 2.5
@export var shuffle_get_up_time: float = 0.9
@export var shuffle_knockback_distance: float = 1.0
@export_range(0.05, 1.0, 0.01) var shuffle_time_scale: float = 0.2
@export_range(0.0, 25.0, 0.1, "suffix:deg") var shuffle_camera_tilt_degrees: float = 8.0
@export_range(0.0, 40.0, 0.1) var shuffle_camera_tilt_speed: float = 18.0
@export var shuffle_debug_enabled: bool = true

@export_group("Lane Change")
@export_range(0.05, 1.0, 0.01, "suffix:s") var lane_tween_duration: float = 0.30
@export_range(0.0, 25.0, 0.1, "suffix:deg") var lane_camera_tilt_degrees: float = 8.0
## Spring stiffness for the camera lean. Higher = snappier, more aggressive
## response. Combined with damping_ratio to produce the spring feel.
@export_range(1.0, 400.0, 1.0) var lane_camera_tilt_stiffness: float = 90.0
## Spring damping ratio. <1.0 underdamped (overshoots and bounces),
## ==1.0 critically damped (no overshoot, fastest settle), >1.0 overdamped
## (sluggish). 0.4-0.6 gives a satisfying snap-and-bounce.
@export_range(0.0, 2.0, 0.01) var lane_camera_tilt_damping_ratio: float = 0.45

var _target_lane: int = START_LANE
var _lane_position: float = float(START_LANE)
var _lane_intent: int = 0
var _tween_from: float = float(START_LANE)
var _tween_elapsed: float = 0.0
var _tween_active: bool = false
var _lane_lean_velocity: float = 0.0
var run_speed: float = 0.0
var _headbob_phase: float = 0.0
var _headbob_offset: float = 0.0
var _shuffle_active: bool = false
var _shuffle_time_left: float = 0.0
var _recovery_time_left: float = 0.0
var _shuffle_deadline_msec: int = 0
var _shuffle_player_direction: int = 0
var _shuffle_camera_lean_direction: int = 0
var _shuffle_npc_direction: int = 0
var _shuffle_npc: NPCCharacter
var _shuffle_ignored_npc: NPCCharacter
var _shuffle_previous_time_scale: float = 1.0
var _shuffle_was_knocked_down: bool = false
var _shuffle_debug_label: Label3D
var _shuffle_fail_reason: String = ""
var _shuffle_recover_started: bool = false
var _movement_blocked: bool = false
var _goal_reached: bool = false

@onready var shuffle_cast: RayCast3D = $ShuffleCast


# Initialize speed and visual state.
func _ready() -> void:
	super()
	add_to_group("player")
	run_speed = start_speed
	if camera_mode == CameraMode.FIRST_PERSON and player_model != null:
		player_model.hide()
	if player_model != null:
		player_model.set_move_speed(run_speed)
	_create_shuffle_debug_label()


# Update camera effects after inherited camera smoothing.
func _process(delta: float) -> void:
	super(delta)
	_update_headbob(delta)
	_update_shuffle_camera_tilt(delta)
	_update_lane_lean(delta)


# Capture shuffle input before it can be consumed by other handlers.
# Outside shuffle, route left/right to lane intent (press) and lane commit (release).
func _input(event: InputEvent) -> void:
	if _shuffle_active:
		if event.is_action_pressed("left"):
			_capture_shuffle_choice(-1)
		elif event.is_action_pressed("right"):
			_capture_shuffle_choice(1)
		elif event.is_action_released("left") or event.is_action_released("right"):
			_shuffle_camera_lean_direction = _get_current_shuffle_input_direction()
		return
	if _recovery_time_left > 0.0 or not _can_move():
		return
	if event.is_action_pressed("left"):
		_on_lane_input_press(-1)
	elif event.is_action_pressed("right"):
		_on_lane_input_press(1)
	elif event.is_action_released("left") or event.is_action_released("right"):
		_on_lane_input_release()


# Handle look and mouse capture input.
func _unhandled_input(event: InputEvent) -> void:
	if _can_look() and camera_rig and event is InputEventMouseMotion:
		_handle_pitch_only(event as InputEventMouseMotion)
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
				else Input.MOUSE_MODE_CAPTURED
	if _shuffle_active:
		if event.is_action_pressed("left"):
			_capture_shuffle_choice(-1)
		elif event.is_action_pressed("right"):
			_capture_shuffle_choice(1)


# Update lane input and run speed.
func _physics_process(delta: float) -> void:
	# Movement is driven externally by the level script via set_position.
	# Here we only handle input and accelerate run_speed toward max_speed.
	if game_state == GameState.DISABLED:
		return
	_update_shuffle(delta)
	if _shuffle_active or _recovery_time_left > 0.0:
		return
	if not _can_move():
		return
	_check_shuffle_cast()
	_update_lane_tween(delta)
	_update_run_speed(delta)
	if player_model != null:
		player_model.set_move_speed(run_speed)


# Return the active lane index for external movement controllers.
# This is the *target* lane (where the player is heading); for the visual
# position during a tween, MetroMovement reads get_lane_position().
func get_current_lane() -> int:
	return _target_lane


# Return the visual lane position as a continuous float (e.g. 1.3 = 30% from
# center to right while tweening). MetroMovement interpolates between
# floor(lane_pos) and ceil(lane_pos) for smooth lane transitions.
func get_lane_position() -> float:
	return _lane_position


# Notify listeners and lock locomotion when the player reaches the goal.
func reach_goal() -> void:
	if _goal_reached:
		return
	_goal_reached = true
	_movement_blocked = false
	run_speed = 0.0
	goal_reached.emit()


# Return whether the player has reached the goal.
func is_goal_reached() -> bool:
	return _goal_reached


# Allow the level controller to flag the runner as blocked by an obstacle.
func set_movement_blocked(blocked: bool) -> void:
	if blocked and not _movement_blocked:
		run_speed = start_speed
	_movement_blocked = blocked


# Return whether the route controller should pause forward travel.
func is_runner_paused() -> bool:
	return _shuffle_active or _recovery_time_left > 0.0 or not _can_move()


# Start a timed left/right dodge prompt.
func start_subway_shuffle(npc: NPCCharacter = null) -> void:
	if _shuffle_active or _recovery_time_left > 0.0:
		return
	if npc == null:
		npc = _get_shuffle_npc()
	if npc == null:
		return
	_shuffle_active = true
	_shuffle_time_left = shuffle_choice_time
	_shuffle_deadline_msec = Time.get_ticks_msec() + int(shuffle_choice_time * 1000.0)
	_shuffle_player_direction = 0
	_shuffle_camera_lean_direction = 0
	_shuffle_npc = npc
	_shuffle_npc_direction = _shuffle_npc.begin_subway_shuffle()
	_shuffle_previous_time_scale = Engine.time_scale
	Engine.time_scale = shuffle_time_scale
	run_speed = 0.0
	# Snap mid-flight tween to nearest integer lane — shuffle direction adds
	# onto a discrete lane, not a fractional position.
	if _tween_active:
		_target_lane = clampi(roundi(_lane_position), 0, LANE_COUNT - 1)
		_lane_position = float(_target_lane)
		_tween_active = false
	_lane_intent = 0
	_debug_shuffle("START npc=%s npc_move=%s" % [_shuffle_npc.name, _direction_name(_shuffle_npc_direction)])
	_set_shuffle_debug_text("NPC %s\nHOLD LEFT/RIGHT" % _direction_name(_shuffle_npc_direction))


# Kill the player and play the death state.
func die() -> void:
	set_camera_mode(CameraMode.THIRD_PERSON)
	set_game_state(GameState.DISABLED)
	if player_model != null:
		player_model.show()
		player_model.play_die()


# Accelerate toward max speed.
func _update_run_speed(delta: float) -> void:
	if _goal_reached:
		run_speed = 0.0
		return
	if _movement_blocked:
		run_speed = start_speed
		return
	if run_speed < max_speed and acceleration_time > 0.0:
		var rate: float = (max_speed - start_speed) / acceleration_time
		run_speed = min(max_speed, run_speed + rate * delta)


# Apply speed-scaled vertical camera headbob.
func _update_headbob(delta: float) -> void:
	if camera_rig == null:
		return

	var target_offset: float = 0.0
	if enable_headbob and game_state == GameState.ACTIVE and _can_move() and run_speed > 0.01 and not _movement_blocked and not _goal_reached:
		_headbob_phase = fmod(_headbob_phase + run_speed * headbob_steps_per_meter * TAU * delta, TAU)
		target_offset = sin(_headbob_phase) * headbob_amplitude

	var t: float = 1.0 if headbob_smoothing <= 0.0 else clamp(headbob_smoothing * delta, 0.0, 1.0)
	_headbob_offset = lerp(_headbob_offset, target_offset, t)
	if abs(_headbob_offset) < 0.0001 and is_zero_approx(target_offset):
		_headbob_offset = 0.0
	camera_rig.set_headbob_offset(_headbob_offset)


# Press handler — set lane intent. Cancels intent if both keys are now held.
# Edge presses (lane 0 left, lane 2 right) still set intent so the camera
# leans in stage 3; commit is gated on bounds in _on_lane_input_release.
func _on_lane_input_press(direction: int) -> void:
	if not _can_move() or _movement_blocked or _goal_reached:
		return
	var both_held: bool = Input.is_action_pressed("left") and Input.is_action_pressed("right")
	_lane_intent = 0 if both_held else direction


# Release handler — commit the lane change if no other key is still held.
# If the other key is still held, intent transfers to it (no commit yet).
# Intent is always cleared at the end so a stale intent can't carry over.
func _on_lane_input_release() -> void:
	var still_held: bool = Input.is_action_pressed("left") or Input.is_action_pressed("right")
	if still_held:
		_lane_intent = -1 if Input.is_action_pressed("left") else 1
		return
	if _can_move() and not _movement_blocked and not _goal_reached:
		var next_lane: int = clampi(_target_lane + _lane_intent, 0, LANE_COUNT - 1)
		if next_lane != _target_lane:
			_commit_lane_change(next_lane)
	_lane_intent = 0


# Resolve the timed subway shuffle prompt.
func _update_shuffle(delta: float) -> void:
	if _recovery_time_left > 0.0 or _shuffle_was_knocked_down:
		if _recovery_time_left > 0.0:
			_recovery_time_left = max(0.0, _recovery_time_left - delta)
		_set_shuffle_debug_text("RECOVER %.2f" % _recovery_time_left)
		if _shuffle_was_knocked_down and not _shuffle_recover_started and _recovery_time_left <= shuffle_get_up_time and _can_start_shuffle_get_up():
			_start_shuffle_get_up()
		if _recovery_time_left <= 0.0 and _shuffle_recover_started:
			if _can_finish_shuffle_recovery():
				_finish_shuffle_recovery()
			else:
				_set_shuffle_debug_text("GET UP")
		return

	if not _shuffle_active:
		return

	_update_shuffle_hold_input()
	_shuffle_time_left = max(0.0, float(_shuffle_deadline_msec - Time.get_ticks_msec()) / 1000.0)
	_set_shuffle_debug_text(
		"NPC %s\nPLAYER %s\n%.2f" % [
			_direction_name(_shuffle_npc_direction),
			_direction_name(_shuffle_player_direction),
			_shuffle_time_left,
		]
	)
	if Time.get_ticks_msec() >= _shuffle_deadline_msec:
		_resolve_subway_shuffle()


# Apply a successful left/right shuffle choice.
func _complete_subway_shuffle(direction: int) -> void:
	_restore_shuffle_time_scale()
	_shuffle_active = false
	run_speed = start_speed
	var npc_direction: int = _shuffle_npc_direction
	if _shuffle_npc != null:
		_shuffle_npc.end_subway_shuffle()
		_shuffle_ignored_npc = _shuffle_npc
		_shuffle_npc = null
	_commit_lane_change(_target_lane + direction)
	_shuffle_player_direction = 0
	_shuffle_camera_lean_direction = 0
	_shuffle_npc_direction = 0
	if direction < 0 and player_model != null:
		player_model.play_interact_left()
	elif direction > 0 and player_model != null:
		player_model.play_interact_right()
	_debug_shuffle("SUCCESS player=%s npc=%s" % [_direction_name(direction), _direction_name(npc_direction)])
	_set_shuffle_debug_text("DODGE %s" % _direction_name(direction))
	subway_shuffle_completed.emit(direction)


# Handle a missed shuffle choice.
func _fail_subway_shuffle() -> void:
	_restore_shuffle_time_scale()
	_shuffle_active = false
	_recovery_time_left = shuffle_recovery_time
	run_speed = start_speed
	if _shuffle_npc != null:
		_shuffle_npc.knock_down_from_shuffle(global_position, shuffle_recovery_time, shuffle_get_up_time, shuffle_knockback_distance)
		_shuffle_ignored_npc = _shuffle_npc
		_shuffle_npc = null
	_shuffle_player_direction = 0
	_shuffle_camera_lean_direction = 0
	_shuffle_npc_direction = 0
	_knock_down_from_shuffle()
	_debug_shuffle("FAIL collision -> knockdown")
	subway_shuffle_failed.emit()


# Knock down immediately when the player catches a same-direction NPC.
func _fail_same_direction_collision(npc: NPCCharacter) -> void:
	_shuffle_active = false
	_shuffle_time_left = 0.0
	_recovery_time_left = shuffle_recovery_time
	_shuffle_player_direction = 0
	_shuffle_camera_lean_direction = 0
	_shuffle_npc_direction = 0
	_shuffle_npc = null
	_shuffle_ignored_npc = npc
	_shuffle_fail_reason = "SAME DIRECTION"
	run_speed = start_speed
	_knock_down_from_shuffle()
	_debug_shuffle("SAME DIRECTION HIT npc=%s -> knockdown" % npc.name)
	subway_shuffle_failed.emit()


# Start a shuffle when the forward ray sees an NPC.
func _check_shuffle_cast() -> void:
	if shuffle_cast == null:
		return
	shuffle_cast.force_raycast_update()
	if not shuffle_cast.is_colliding():
		_shuffle_ignored_npc = null
		return
	var collider: Object = shuffle_cast.get_collider()
	if collider is NPCCharacter and (collider as NPCCharacter).is_in_group("npc"):
		var npc: NPCCharacter = collider as NPCCharacter
		if npc == _shuffle_ignored_npc:
			return
		if _should_skip_shuffle_for_same_direction(npc):
			_fail_same_direction_collision(npc)
			return
		start_subway_shuffle(npc)


# Return whether an NPC is moving with the player and should not start shuffle.
func _should_skip_shuffle_for_same_direction(npc: NPCCharacter) -> bool:
	return npc.is_routing_to_finish_point()


# Update the held player direction during bullet time.
func _update_shuffle_hold_input() -> void:
	var direction: int = _get_current_shuffle_input_direction()
	if direction == 0:
		return
	_capture_shuffle_choice(direction)


# Capture a non-zero player choice for shuffle resolution.
func _capture_shuffle_choice(direction: int) -> void:
	_shuffle_camera_lean_direction = direction
	if direction == _shuffle_player_direction:
		return
	_shuffle_player_direction = direction
	_debug_shuffle("HOLD player=%s npc=%s time=%.2f" % [
		_direction_name(_shuffle_player_direction),
		_direction_name(_shuffle_npc_direction),
		_shuffle_time_left,
	])
	if direction < 0 and player_model != null:
		player_model.play_interact_left()
	elif direction > 0 and player_model != null:
		player_model.play_interact_right()


# Return the current held left/right shuffle input.
func _get_current_shuffle_input_direction() -> int:
	var direction: int = 0
	if Input.is_action_pressed("left"):
		direction -= 1
	if Input.is_action_pressed("right"):
		direction += 1
	return clampi(direction, -1, 1)


# Roll the first-person camera toward the currently held shuffle lean.
# Only runs during shuffle (held tilt) or recovery (settle to neutral). Outside
# those windows, lane lean owns camera_rig.rotation.z — without the early-out
# this function's lerp-toward-zero would fight the spring every frame and
# suppress its overshoot.
func _update_shuffle_camera_tilt(delta: float) -> void:
	if camera_rig == null:
		return
	if not _shuffle_active and _recovery_time_left <= 0.0:
		return
	var target_tilt: float = 0.0
	if _shuffle_active:
		_shuffle_camera_lean_direction = _get_current_shuffle_input_direction()
		target_tilt = -deg_to_rad(shuffle_camera_tilt_degrees) * float(_shuffle_camera_lean_direction)
	var tilt_delta: float = delta / maxf(Engine.time_scale, 0.001)
	var weight: float = 1.0 if shuffle_camera_tilt_speed <= 0.0 else clamp(shuffle_camera_tilt_speed * tilt_delta, 0.0, 1.0)
	camera_rig.rotation.z = lerp_angle(camera_rig.rotation.z, target_tilt, weight)
	if abs(camera_rig.rotation.z) < 0.001 and is_zero_approx(target_tilt):
		camera_rig.rotation.z = 0.0


# Roll the first-person camera toward the held lane intent, then decay through
# the body tween via 1 - sqrt(t) so the lean follows through and uprights as
# the body settles. Driven by a spring-damper so it overshoots and bounces
# when underdamped. Mutually exclusive with shuffle tilt — shuffle wins;
# velocity is parked at 0 during shuffle so the lean restarts cleanly.
func _update_lane_lean(delta: float) -> void:
	if camera_rig == null:
		return
	if _shuffle_active or _recovery_time_left > 0.0:
		_lane_lean_velocity = 0.0
		return
	var target_tilt: float = 0.0
	if _lane_intent != 0:
		# Hold phase — full tilt toward intent.
		target_tilt = -deg_to_rad(lane_camera_tilt_degrees) * float(_lane_intent)
	elif _tween_active:
		# Follow-through during body tween — decay tilt as body settles.
		var travel_dir: int = signi(float(_target_lane) - _tween_from)
		if travel_dir != 0:
			var raw: float = clampf(_tween_elapsed / maxf(lane_tween_duration, 0.001), 0.0, 1.0)
			var follow: float = 1.0 - sqrt(raw)
			target_tilt = -deg_to_rad(lane_camera_tilt_degrees) * float(travel_dir) * follow
	# Semi-implicit Euler spring step. Critical damping coefficient at mass=1
	# is 2*sqrt(stiffness); damping_ratio scales it. Ratio < 1 produces
	# overshoot and bounce; ratio == 1 is critical (fastest no-overshoot).
	var current: float = camera_rig.rotation.z
	var damping: float = 2.0 * sqrt(lane_camera_tilt_stiffness) * lane_camera_tilt_damping_ratio
	var acceleration: float = lane_camera_tilt_stiffness * (target_tilt - current) - damping * _lane_lean_velocity
	_lane_lean_velocity += acceleration * delta
	var next: float = current + _lane_lean_velocity * delta
	# Settle exactly when both displacement and velocity are tiny — avoids
	# infinite micro-oscillation around zero from float noise.
	if absf(_lane_lean_velocity) < 0.01 and absf(next - target_tilt) < 0.001:
		next = target_tilt
		_lane_lean_velocity = 0.0
	camera_rig.rotation.z = next


# Resolve held input by comparing each character's world-space side step.
func _resolve_subway_shuffle() -> void:
	var _collision: bool = _shuffle_choices_collide()
	_debug_shuffle("RESOLVE player=%s npc=%s collide=%s" % [
		_direction_name(_shuffle_player_direction),
		_direction_name(_shuffle_npc_direction),
		_collision,
	])
	if _shuffle_player_direction == 0:
		_shuffle_fail_reason = "NO INPUT"
		_debug_shuffle("LOSE no held direction")
		_set_shuffle_debug_text("LOSE\nNO INPUT")
		_fail_subway_shuffle()
	elif _collision:
		_shuffle_fail_reason = "SAME SIDE"
		_debug_shuffle("LOSE same world side")
		_set_shuffle_debug_text("LOSE\nSAME WORLD SIDE")
		_fail_subway_shuffle()
	else:
		_complete_subway_shuffle(_shuffle_player_direction)


# Return whether the player and NPC chose the same world-space side.
func _shuffle_choices_collide() -> bool:
	if _shuffle_npc == null or _shuffle_player_direction == 0 or _shuffle_npc_direction == 0:
		return _shuffle_player_direction == 0
	var player_side: Vector3 = global_transform.basis.x * float(_shuffle_player_direction)
	var npc_side: Vector3 = _shuffle_npc.global_transform.basis.x * float(_shuffle_npc_direction)
	player_side.y = 0.0
	npc_side.y = 0.0
	if player_side.length_squared() <= 0.001 or npc_side.length_squared() <= 0.001:
		return _shuffle_player_direction != _shuffle_npc_direction
	var side_dot: float = player_side.normalized().dot(npc_side.normalized())
	_debug_shuffle("WORLD SIDE DOT %.2f player=%s npc=%s" % [
		side_dot,
		_direction_name(_shuffle_player_direction),
		_direction_name(_shuffle_npc_direction),
	])
	return side_dot > 0.0


# Return the NPC currently seen by the shuffle ray.
func _get_shuffle_npc() -> NPCCharacter:
	if shuffle_cast == null:
		return null
	shuffle_cast.force_raycast_update()
	if not shuffle_cast.is_colliding():
		return null
	var collider: Object = shuffle_cast.get_collider()
	if collider is NPCCharacter and (collider as NPCCharacter).is_in_group("npc"):
		if collider == _shuffle_ignored_npc:
			return null
		return collider as NPCCharacter
	return null


# Restore normal game time after bullet time.
func _restore_shuffle_time_scale() -> void:
	Engine.time_scale = _shuffle_previous_time_scale


# Play the collision knockdown without permanently disabling the runner.
func _knock_down_from_shuffle() -> void:
	if _shuffle_was_knocked_down:
		return
	_shuffle_was_knocked_down = true
	_shuffle_recover_started = false
	set_camera_mode(CameraMode.THIRD_PERSON)
	if player_model != null:
		player_model.show()
		player_model.play_die()
	_set_shuffle_debug_text("COLLISION\n%s" % _shuffle_fail_reason)


# Play the get-up animation before control returns.
func _start_shuffle_get_up() -> void:
	if not _can_start_shuffle_get_up():
		return
	_shuffle_recover_started = true
	if player_model != null:
		player_model.play_recover()
	_set_shuffle_debug_text("GET UP")
	_debug_shuffle("GET UP")


# Return whether die playback is finished and get-up can begin.
func _can_start_shuffle_get_up() -> bool:
	return player_model == null or player_model.can_start_recover()


# Return whether the recover animation has finished owning player visuals.
func _can_finish_shuffle_recovery() -> bool:
	return player_model == null or not player_model.is_recovery_locked()


# Restore locomotion after the knockdown timer finishes.
func _finish_shuffle_recovery() -> void:
	if player_model != null:
		player_model.play_walk()
	_shuffle_was_knocked_down = false
	_shuffle_recover_started = false
	_shuffle_fail_reason = ""
	run_speed = start_speed
	# Require a fresh press to lane-change after recovery — any key still held
	# from before the knockdown shouldn't auto-commit.
	_lane_intent = 0
	set_game_state(GameState.ACTIVE)
	set_camera_mode(CameraMode.FIRST_PERSON)
	if player_model != null:
		player_model.hide()
	_set_shuffle_debug_text("RECOVERED")
	_debug_shuffle("RECOVERED run_speed=%.2f" % run_speed)


# Create a small in-world debug label above the player.
func _create_shuffle_debug_label() -> void:
	if not shuffle_debug_enabled or _shuffle_debug_label != null:
		return
	_shuffle_debug_label = Label3D.new()
	_shuffle_debug_label.name = "ShuffleDebugLabel"
	_shuffle_debug_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_shuffle_debug_label.no_depth_test = true
	_shuffle_debug_label.font_size = 32
	_shuffle_debug_label.modulate = Color(0.2, 0.8, 1.0, 1.0)
	_shuffle_debug_label.position = Vector3(0.0, 2.4, 0.0)
	add_child(_shuffle_debug_label)


# Update the player shuffle debug text.
func _set_shuffle_debug_text(text: String) -> void:
	if not shuffle_debug_enabled:
		return
	_create_shuffle_debug_label()
	if _shuffle_debug_label != null:
		_shuffle_debug_label.text = text


# Print shuffle state changes to the console.
func _debug_shuffle(message: String) -> void:
	if shuffle_debug_enabled:
		print("[Shuffle][Player] %s" % message)


# Return a readable direction label.
func _direction_name(direction: int) -> String:
	if direction < 0:
		return "LEFT"
	if direction > 0:
		return "RIGHT"
	return "NONE"


# Update the target lane and start the visual tween. _tween_from = current
# visual position so mid-tween interrupts restart smoothly from where the body
# actually is rather than snapping back to the previous integer lane.
func _commit_lane_change(next_lane: int) -> void:
	var clamped_lane: int = clampi(next_lane, 0, LANE_COUNT - 1)
	if clamped_lane == _target_lane:
		return
	_target_lane = clamped_lane
	_tween_from = _lane_position
	_tween_elapsed = 0.0
	_tween_active = true
	lane_changed.emit()


# Advance the sqrt-eased lane tween. sqrt easing is fast-departure, soft-arrival
# — the body launches the instant the player releases and decelerates into the
# new lane.
func _update_lane_tween(delta: float) -> void:
	if not _tween_active:
		return
	_tween_elapsed += delta
	var raw: float = clampf(_tween_elapsed / maxf(lane_tween_duration, 0.001), 0.0, 1.0)
	var eased: float = sqrt(raw)
	_lane_position = lerp(_tween_from, float(_target_lane), eased)
	if raw >= 1.0:
		_lane_position = float(_target_lane)
		_tween_active = false


# Disable inherited direct movement input.
func _gather_movement_input() -> void:
	move_dir = Vector3.ZERO
	move_input = Vector2.ZERO
	wish_sprint = false
	wish_jump = false
	wish_crouch = false


# Prevent inherited movement while the runner is resolving an encounter.
func _can_move() -> bool:
	return game_state == GameState.ACTIVE


# Apply first-person pitch while external code drives translation.
func _handle_pitch_only(event: InputEventMouseMotion) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	var relative: Vector2 = event.relative
	relative *= config.mouse_sensitivity * deg_to_rad(config.degrees_per_unit)

	var invert: float = -1.0 if camera_rig.invert_mouse_y else 1.0
	camera_rig.rotate_object_local(Vector3.RIGHT, invert * -relative.y)
	camera_rig.rotation.x = clamp(
		camera_rig.rotation.x,
		deg_to_rad(-SUCCCamera.PITCH_LIMIT_DEG),
		deg_to_rad(SUCCCamera.PITCH_LIMIT_DEG)
	)
	camera_rig.orthonormalize()
