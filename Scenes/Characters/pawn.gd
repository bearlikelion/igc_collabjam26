class_name Pawn
extends CharacterBody3D

# Unified actor for the metro auto-runner. Both player and NPC instances are
# Pawns; behavior diverges via a Brain Resource assigned to the brain export.
# MetroMovement writes global_position every physics frame from
# get_current_lane() / get_lane_position(); Pawn never calls move_and_slide().
#
# Pawn owns the BODY and its SENSES:
#   - Lane state (target lane + sqrt-eased tween position)
#   - Knockdown / recovery lifecycle
#   - Subway-shuffle resolver (initiator-side: deadline timer + world-side compare)
#   - Subway-shuffle participant state (callee-side: telegraph + side-step)
#   - ShuffleCast forward detection (a "sense": emits encounter_detected)
#   - Camera (a "sense": mouse pitch input, headbob, lane-lean spring,
#     shuffle camera tilt, mode flip on knockdown — all owned by Pawn)
#   - Bullet-time on shuffle (player-flagged via apply_bullet_time)
#   - Visual animation playback (die, recover, walk, interact_*)
#   - Visual show/hide tied to camera mode
#
# Brain owns DECISIONS only:
#   - Translates Pawn signals into intent calls (request_lane_change,
#     start_shuffle, set_shuffle_telegraph, lean)
#   - PlayerBrain reads keyboard via process_input forwarded from Pawn;
#     AIBrain ticks msec timers via physics_tick forwarded from Pawn.
#
# Brain is a Resource (not a Node). Pawn._ready calls brain.bind(self), which
# stores the pawn ref and connects to Pawn's signal protocol. metro_1.tscn
# assigns the brain export per Pawn instance (PlayerBrain.tres / AIBrain.tres).

# Lane geometry — single source of truth, also read by MetroMovement.
const LANE_OFFSETS: Array[float] = [-1.0, 0.0, 1.0]
const LANE_COUNT: int = 3
const START_LANE: int = LANE_COUNT / 2

enum GameState { ACTIVE, FROZEN, DISABLED }
enum RailDirection { FORWARD, REVERSE }

# --- Signals: Pawn → Brain (results out) -----------------------------------

# Locomotion telemetry — what's happening to my body.
signal lane_change_started(from_lane: int, to_lane: int)
signal lane_change_completed(lane: int)
signal lane_change_canceled()
signal goal_reached()

# Encounter events.
signal encounter_detected(other: Pawn, distance: float)
signal shuffle_began(other: Pawn, other_telegraph: int, deadline_msec: int)
signal shuffle_telegraph_changed(direction: int)
signal shuffle_resolved(succeeded: bool, direction: int)
signal knocked_down()
signal recovery_started()
signal recovered()

# Planning events.
signal obstacle_detected(other: Pawn, distance: float, in_lane: int)

# Game state lifecycle.
signal game_state_changed(old_state: int, new_state: int)


# --- Exports ---------------------------------------------------------------

@export_group("Brain")
## The Brain Resource that decides intent for this Pawn. Player Pawn instances
## point this at PlayerBrain.tres; NPC instances at AIBrain.tres. Pawn calls
## brain.bind(self) on _ready to wire up signals + give Brain its pawn ref.
@export var brain: Brain

@export_group("Camera")
## When true, Pawn marks its Camera3D as current and captures the mouse on
## _ready. NPCs leave this false; only the player Pawn instance enables it.
@export var is_active_camera: bool = false
## When true, Pawn applies Engine.time_scale = shuffle_time_scale on shuffle
## start and restores it on resolve. Player-only effect; NPCs leave it false.
@export var apply_bullet_time: bool = false

@export_group("Run Speed")
@export var start_speed: float = 0.5
@export var max_speed: float = 3.0
## Time in seconds to accelerate from start_speed to max_speed.
@export var acceleration_time: float = 10.0

@export_group("Lane Change")
@export_range(0.05, 1.0, 0.01, "suffix:s") var lane_tween_duration: float = 0.30

@export_group("Subway Shuffle")
## Bullet-time window during which the initiating brain commits a side.
@export var shuffle_choice_time: float = 0.5
@export_range(0.05, 1.0, 0.01) var shuffle_time_scale: float = 0.2
## Side-step displacement when a callee survives a shuffle (lerp duration is
## shuffle_lane_move_time). Initiator does NOT side-step — it lane-changes.
@export var shuffle_lane_distance: float = 1.0
@export var shuffle_lane_move_time: float = 0.25
@export var shuffle_debug_enabled: bool = false

@export_group("Knockdown")
## Total knockdown lockout in seconds.
@export var shuffle_recovery_time: float = 2.5
## Get-up window inside the lockout — recover anim starts when remaining ≤ this.
@export var shuffle_get_up_time: float = 1.0
## Distance to push the pawn away from the impact origin on knockdown.
@export var shuffle_knockback_distance: float = 2.0

@export_group("Rail")
@export var rail_direction: RailDirection = RailDirection.FORWARD
@export var rail_start_distance: float = 0.0
@export var rail_speed: float = 1.8
@export_range(0.0, 1.0, 0.01) var rail_speed_variance: float = 0.3

@export_group("Lane Behavior")
@export var avoid_obstacles: bool = false
@export var obstacle_lookahead: float = 2.5
## Seconds after an avoidance lane change before AI brains will swerve again.
## Read by AIBrain off its bound pawn.
@export var avoidance_cooldown: float = 0.6

@export_group("Mouse")
@export var mouse_sensitivity: float = 3.0
## Source-engine scale: degrees of view rotation per mouse "unit". 0.022 = Source default.
@export var degrees_per_unit: float = 0.022

@export_group("Headbob")
@export var enable_headbob: bool = true
@export_range(0.0, 0.2, 0.001, "suffix:m") var headbob_amplitude: float = 0.025
@export_range(0.0, 6.0, 0.05, "suffix:steps/m") var headbob_steps_per_meter: float = 0.65
@export_range(0.0, 30.0, 0.1) var headbob_smoothing: float = 12.0

@export_group("Lane Lean")
@export_range(0.0, 25.0, 0.1, "suffix:deg") var lane_camera_tilt_degrees: float = 8.0
## Spring stiffness for the camera lean. Higher = snappier.
@export_range(1.0, 400.0, 1.0) var lane_camera_tilt_stiffness: float = 90.0
## Spring damping ratio. <1 underdamped, ==1 critical, >1 overdamped. ~0.45 = bouncy.
@export_range(0.0, 2.0, 0.01) var lane_camera_tilt_damping_ratio: float = 0.45

@export_group("Shuffle Camera Tilt")
@export_range(0.0, 25.0, 0.1, "suffix:deg") var shuffle_camera_tilt_degrees: float = 8.0
@export_range(0.0, 40.0, 0.1) var shuffle_camera_tilt_speed: float = 18.0

@export_group("Visual")
@export var visual: CharacterVisual


@onready var shuffle_cast: RayCast3D = get_node_or_null("ShuffleCast")
@onready var camera_rig: PawnCamera = get_node_or_null("CameraRig")


# --- State ----------------------------------------------------------------

var run_speed: float = 0.0
var game_state: int = GameState.ACTIVE

# Lane state.
var _target_lane: int = START_LANE
var _lane_position: float = float(START_LANE)
var _tween_from: float = float(START_LANE)
var _tween_elapsed: float = 0.0
var _tween_active: bool = false

# Knockdown state.
var _knockdown_active: bool = false
var _recovery_time_left: float = 0.0
var _recover_started: bool = false

# Shuffle state. _shuffle_is_initiator distinguishes "I started this shuffle and
# own the resolver" from "I'm a callee — my brain just picks a telegraph".
var _shuffle_active: bool = false
var _shuffle_is_initiator: bool = false
var _shuffle_time_left: float = 0.0
var _shuffle_deadline_msec: int = 0
var _shuffle_player_direction: int = 0
var _shuffle_npc_direction: int = 0
var _shuffle_other: Pawn
var _shuffle_ignored_other: Pawn

# Side-step state.
var _shuffle_lane_move_active: bool = false
var _shuffle_lane_start_position: Vector3 = Vector3.ZERO
var _shuffle_lane_target_position: Vector3 = Vector3.ZERO
var _shuffle_lane_elapsed: float = 0.0

# Parking state (FORWARD pawns at end of rail).
var _parked_at_finish: bool = false
var _parked_offset: Vector3 = Vector3.ZERO

# Camera-driven state (Pawn owns these — the camera is a "sense").
var _headbob_phase: float = 0.0
var _headbob_offset: float = 0.0
var _lane_lean_velocity: float = 0.0
var _shuffle_camera_lean_direction: int = 0
var _shuffle_previous_time_scale: float = 1.0

var _movement_blocked: bool = false
var _goal_reached: bool = false
var _actual_rail_speed: float = 0.0


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	run_speed = start_speed
	# Activate camera if this Pawn is the player.
	if is_active_camera and camera_rig != null:
		var cam: Camera3D = camera_rig.get_node_or_null("Camera3D")
		if cam != null:
			cam.current = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		if visual != null:
			visual.hide()  # Hide own body in first-person.
	# Bind the brain (Brain is a Resource; bind stores the pawn ref and wires
	# signal handlers).
	if brain != null:
		brain.bind(self)


func _physics_process(delta: float) -> void:
	if game_state == GameState.DISABLED:
		return
	if is_knocked_down():
		_update_knockdown_recovery(delta)
		return
	if _shuffle_lane_move_active:
		_update_shuffle_lane_move(delta)
		return
	_update_shuffle(delta)
	if _shuffle_active:
		if brain != null:
			brain.physics_tick(delta)
		return
	if not can_move():
		return
	_check_shuffle_cast()
	_update_lane_tween(delta)
	_update_run_speed(delta)
	if visual != null:
		visual.set_move_speed(run_speed)
	if brain != null:
		brain.physics_tick(delta)


func _process(delta: float) -> void:
	if camera_rig == null:
		return
	_update_headbob(delta)
	_update_shuffle_camera_tilt(delta)
	_update_lane_lean(delta)


# Camera mouse-look + mouse-mode toggle, then forward to brain. Mouse handling
# only runs when this Pawn has an active camera (player only).
func _input(event: InputEvent) -> void:
	if is_active_camera and camera_rig != null:
		if can_look() and event is InputEventMouseMotion:
			_handle_pitch_only(event as InputEventMouseMotion)
		if event.is_action_pressed("ui_cancel"):
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
					else Input.MOUSE_MODE_CAPTURED
	if brain != null:
		brain.process_input(event)


# --- Public API: Brain → Pawn (intent in) ---------------------------------

# Brain commits to a discrete lane. Tweens unless instant=true.
func request_lane_change(target_lane: int, instant: bool = false) -> void:
	if not can_move() or _movement_blocked or _goal_reached or _shuffle_active or is_knocked_down():
		return
	if instant:
		_target_lane = clampi(target_lane, 0, LANE_COUNT - 1)
		_lane_position = float(_target_lane)
		_tween_active = false
	else:
		_commit_lane_change(target_lane)


# Brain initiates a shuffle encounter. This Pawn becomes the initiator.
func start_shuffle(other: Pawn) -> void:
	if _shuffle_active or is_knocked_down() or other == null:
		return
	_shuffle_active = true
	_shuffle_is_initiator = true
	_shuffle_time_left = shuffle_choice_time
	_shuffle_deadline_msec = Time.get_ticks_msec() + int(shuffle_choice_time * 1000.0)
	_shuffle_player_direction = 0
	_shuffle_other = other
	run_speed = 0.0
	if _tween_active:
		_target_lane = clampi(roundi(_lane_position), 0, LANE_COUNT - 1)
		_lane_position = float(_target_lane)
		_tween_active = false
		lane_change_canceled.emit()
	_shuffle_npc_direction = other.begin_subway_shuffle(self, _shuffle_deadline_msec)
	if apply_bullet_time:
		_shuffle_previous_time_scale = Engine.time_scale
		Engine.time_scale = shuffle_time_scale
	shuffle_began.emit(other, _shuffle_npc_direction, _shuffle_deadline_msec)


# Brain commits a shuffle direction.
func set_shuffle_telegraph(direction: int) -> void:
	if not _shuffle_active:
		return
	var clamped: int = clampi(direction, -1, 1)
	if clamped == _shuffle_player_direction:
		return
	_shuffle_player_direction = clamped
	_shuffle_camera_lean_direction = clamped
	if _shuffle_other != null:
		_shuffle_other.shuffle_telegraph_changed.emit(clamped)


# Brain announces a visible body lean. Routes to torso-lean animation; player
# Pawn also drives camera roll via lane-lean spring (held intent).
func lean(direction: int) -> void:
	_shuffle_camera_lean_direction = direction
	if visual == null:
		return
	if direction < 0:
		visual.play_interact_left()
	elif direction > 0:
		visual.play_interact_right()


# Mark a Pawn as ignored for forward-cast detection until the cast no longer
# hits it. Used by PlayerBrain on same-direction-collision instant-knockdown
# so the cast doesn't re-trigger the same encounter on recovery.
func set_shuffle_ignored(other: Pawn) -> void:
	_shuffle_ignored_other = other


# --- Subway-shuffle participant hooks (called by initiator on callee) -----

func begin_subway_shuffle(from: Pawn, deadline_msec: int) -> int:
	_shuffle_active = true
	_shuffle_is_initiator = false
	_shuffle_other = from
	_shuffle_deadline_msec = deadline_msec
	_shuffle_player_direction = 0
	shuffle_began.emit(from, 0, deadline_msec)
	return _shuffle_player_direction


func end_subway_shuffle() -> void:
	var direction: int = _shuffle_player_direction
	_start_shuffle_lane_move(direction)
	_shuffle_active = false
	_shuffle_is_initiator = false
	_shuffle_player_direction = 0
	_shuffle_camera_lean_direction = 0
	_shuffle_other = null
	if visual != null:
		visual.play_walk()


func stop_subway_shuffle() -> void:
	_shuffle_active = false
	_shuffle_is_initiator = false
	_shuffle_player_direction = 0
	_shuffle_camera_lean_direction = 0
	_shuffle_lane_move_active = false


# --- Public API: queries --------------------------------------------------

func get_current_lane() -> int:
	return _target_lane


func set_current_lane(lane: int) -> void:
	_target_lane = clampi(lane, 0, LANE_COUNT - 1)
	_lane_position = float(_target_lane)
	_tween_active = false


func get_lane_position() -> float:
	return _lane_position


func get_rail_direction() -> int:
	return rail_direction


func get_rail_start_distance() -> float:
	return rail_start_distance


func get_rail_speed() -> float:
	if _actual_rail_speed <= 0.0:
		_roll_actual_rail_speed()
	return _actual_rail_speed


func get_shuffle_telegraph() -> int:
	return _shuffle_player_direction


func is_runner_paused() -> bool:
	return _shuffle_active or is_knocked_down() or not can_move() or _shuffle_lane_move_active


func is_routing_to_finish_point() -> bool:
	return rail_direction == RailDirection.FORWARD


func is_shuffle_active() -> bool:
	return _shuffle_active


func should_avoid_obstacles() -> bool:
	return avoid_obstacles


func get_obstacle_lookahead() -> float:
	return obstacle_lookahead


func reach_goal() -> void:
	if _goal_reached:
		return
	_goal_reached = true
	_movement_blocked = false
	run_speed = 0.0
	goal_reached.emit()


func is_goal_reached() -> bool:
	return _goal_reached


func set_movement_blocked(blocked: bool) -> void:
	if blocked and not _movement_blocked:
		run_speed = start_speed
	_movement_blocked = blocked


func is_movement_blocked() -> bool:
	return _movement_blocked


# --- Parking (FORWARD pawns at end of rail) -------------------------------

func park_at_finish(offset: Vector3) -> void:
	_parked_at_finish = true
	_parked_offset = offset
	if visual != null:
		visual.pause_animation()


func is_parked_at_finish() -> bool:
	return _parked_at_finish


func get_parked_offset() -> Vector3:
	return _parked_offset


# --- Knockdown lifecycle ---------------------------------------------------

func knock_down_from_shuffle() -> void:
	if _knockdown_active:
		return
	_knockdown_active = true
	_recover_started = false
	_recovery_time_left = maxf(shuffle_recovery_time, shuffle_get_up_time)
	# Player flips to third-person and shows its body during knockdown.
	if is_active_camera and camera_rig != null:
		camera_rig.apply_mode(PawnCamera.Mode.THIRD_PERSON)
	if visual != null:
		visual.show()
		visual.play_die()
	knocked_down.emit()


func apply_knockback_from(origin: Vector3) -> void:
	var direction: Vector3 = global_position - origin
	direction.y = 0.0
	if direction.length_squared() <= 0.001:
		direction = global_transform.basis.z
		direction.y = 0.0
	if direction.length_squared() <= 0.001:
		direction = Vector3.BACK
	direction = direction.normalized()
	global_position += direction * shuffle_knockback_distance


func _update_knockdown_recovery(delta: float) -> void:
	if not _knockdown_active:
		return
	if _recovery_time_left > 0.0:
		_recovery_time_left = maxf(0.0, _recovery_time_left - delta)
	if not _recover_started and _recovery_time_left <= shuffle_get_up_time and _can_start_recover():
		_recover_started = true
		if visual != null:
			visual.play_recover()
		recovery_started.emit()
	if _recovery_time_left <= 0.0 and _recover_started and _can_finish_recovery():
		_finish_knockdown_recovery()


func _finish_knockdown_recovery() -> void:
	_knockdown_active = false
	_recover_started = false
	if visual != null:
		visual.play_walk()
	run_speed = start_speed
	# Player flips back to first-person and re-hides its body.
	if is_active_camera and camera_rig != null:
		camera_rig.apply_mode(PawnCamera.Mode.FIRST_PERSON)
		if visual != null:
			visual.hide()
	recovered.emit()


func is_knocked_down() -> bool:
	return _knockdown_active


func _can_start_recover() -> bool:
	return visual == null or visual.can_start_recover()


func _can_finish_recovery() -> bool:
	return visual == null or not visual.is_recovery_locked()


# --- Game state -----------------------------------------------------------

func set_game_state(new_state: int) -> void:
	if new_state == game_state:
		return
	var old_state: int = game_state
	game_state = new_state
	game_state_changed.emit(old_state, new_state)


func can_move() -> bool:
	return game_state == GameState.ACTIVE


func can_look() -> bool:
	return game_state != GameState.DISABLED


func die() -> void:
	set_game_state(GameState.DISABLED)
	if visual != null:
		visual.show()
		visual.play_die()


# --- Tween state read accessors (for camera lane-lean spring) -------------

func is_tween_active() -> bool:
	return _tween_active


func get_tween_from() -> float:
	return _tween_from


func get_tween_progress() -> float:
	if not _tween_active or lane_tween_duration <= 0.0:
		return 0.0
	return clampf(_tween_elapsed / lane_tween_duration, 0.0, 1.0)


# --- Internal --------------------------------------------------------------

func _commit_lane_change(next_lane: int) -> void:
	var clamped_lane: int = clampi(next_lane, 0, LANE_COUNT - 1)
	if clamped_lane == _target_lane:
		return
	var from_lane: int = _target_lane
	_target_lane = clamped_lane
	_tween_from = _lane_position
	_tween_elapsed = 0.0
	_tween_active = true
	lane_change_started.emit(from_lane, clamped_lane)


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
		lane_change_completed.emit(_target_lane)


# Initiator-only: tick deadline, resolve when expired.
func _update_shuffle(_delta: float) -> void:
	if not _shuffle_active or not _shuffle_is_initiator:
		return
	_shuffle_time_left = max(0.0, float(_shuffle_deadline_msec - Time.get_ticks_msec()) / 1000.0)
	if Time.get_ticks_msec() >= _shuffle_deadline_msec:
		_resolve_subway_shuffle()


func _resolve_subway_shuffle() -> void:
	if _shuffle_other != null:
		_shuffle_npc_direction = _shuffle_other.get_shuffle_telegraph()
	var collision: bool = _shuffle_choices_collide()
	var succeeded: bool = false
	var direction: int = 0
	if _shuffle_player_direction != 0 and not collision:
		succeeded = true
		direction = _shuffle_player_direction
	if succeeded:
		_complete_subway_shuffle(direction)
	else:
		_fail_subway_shuffle()


func _complete_subway_shuffle(direction: int) -> void:
	_shuffle_active = false
	_shuffle_is_initiator = false
	run_speed = start_speed
	if apply_bullet_time:
		Engine.time_scale = _shuffle_previous_time_scale
	if _shuffle_other != null:
		_shuffle_other.end_subway_shuffle()
		_shuffle_ignored_other = _shuffle_other
		_shuffle_other = null
	_commit_lane_change(_target_lane + direction)
	_shuffle_player_direction = 0
	_shuffle_npc_direction = 0
	_shuffle_camera_lean_direction = 0
	if direction < 0 and visual != null:
		visual.play_interact_left()
	elif direction > 0 and visual != null:
		visual.play_interact_right()
	shuffle_resolved.emit(true, direction)


func _fail_subway_shuffle() -> void:
	_shuffle_active = false
	_shuffle_is_initiator = false
	run_speed = start_speed
	if apply_bullet_time:
		Engine.time_scale = _shuffle_previous_time_scale
	if _shuffle_other != null:
		_shuffle_other.apply_knockback_from(global_position)
		_shuffle_other.knock_down_from_shuffle()
		_shuffle_ignored_other = _shuffle_other
		_shuffle_other = null
	_shuffle_player_direction = 0
	_shuffle_npc_direction = 0
	_shuffle_camera_lean_direction = 0
	knock_down_from_shuffle()
	shuffle_resolved.emit(false, 0)


func _shuffle_choices_collide() -> bool:
	if _shuffle_other == null or _shuffle_player_direction == 0 or _shuffle_npc_direction == 0:
		return _shuffle_player_direction == 0
	var player_side: Vector3 = global_transform.basis.x * float(_shuffle_player_direction)
	var npc_side: Vector3 = _shuffle_other.global_transform.basis.x * float(_shuffle_npc_direction)
	player_side.y = 0.0
	npc_side.y = 0.0
	if player_side.length_squared() <= 0.001 or npc_side.length_squared() <= 0.001:
		return _shuffle_player_direction != _shuffle_npc_direction
	var side_dot: float = player_side.normalized().dot(npc_side.normalized())
	return side_dot > 0.0


func _check_shuffle_cast() -> void:
	if shuffle_cast == null:
		return
	shuffle_cast.force_raycast_update()
	if not shuffle_cast.is_colliding():
		_shuffle_ignored_other = null
		return
	var collider: Object = shuffle_cast.get_collider()
	if collider is Pawn:
		var other: Pawn = collider as Pawn
		if other == _shuffle_ignored_other or other == self:
			return
		var distance: float = global_position.distance_to(other.global_position)
		encounter_detected.emit(other, distance)


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


func _roll_actual_rail_speed() -> void:
	var jitter: float = (randf() * 2.0 - 1.0) * rail_speed_variance
	_actual_rail_speed = maxf(0.1, rail_speed * (1.0 + jitter))


# --- Side-step ------------------------------------------------------------

func _start_shuffle_lane_move(direction: int) -> void:
	if direction == 0:
		return
	var lane_direction: Vector3 = global_transform.basis.x * float(direction)
	lane_direction.y = 0.0
	if lane_direction.length_squared() <= 0.001 or is_zero_approx(shuffle_lane_distance):
		return
	_shuffle_lane_start_position = global_position
	_shuffle_lane_target_position = global_position + lane_direction.normalized() * shuffle_lane_distance
	_shuffle_lane_elapsed = 0.0
	_shuffle_lane_move_active = true


func _update_shuffle_lane_move(delta: float) -> void:
	if not _shuffle_lane_move_active:
		return
	var scaled_delta: float = delta / maxf(Engine.time_scale, 0.001)
	_shuffle_lane_elapsed += scaled_delta
	var duration: float = maxf(shuffle_lane_move_time, 0.001)
	var weight: float = clampf(_shuffle_lane_elapsed / duration, 0.0, 1.0)
	var next_position: Vector3 = _shuffle_lane_start_position.lerp(_shuffle_lane_target_position, weight)
	next_position.y = global_position.y
	global_position = next_position
	if weight >= 1.0:
		_shuffle_lane_move_active = false


# --- Camera ("sense") -----------------------------------------------------

# Apply first-person pitch to the camera rig. Yaw is owned by MetroMovement's
# rail-following lerp; this only handles pitch (X rotation).
func _handle_pitch_only(event: InputEventMouseMotion) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	var relative: Vector2 = event.relative
	relative *= mouse_sensitivity * deg_to_rad(degrees_per_unit)
	var invert: float = -1.0 if camera_rig.invert_mouse_y else 1.0
	camera_rig.rotate_object_local(Vector3.RIGHT, invert * -relative.y)
	camera_rig.rotation.x = clamp(
		camera_rig.rotation.x,
		deg_to_rad(-PawnCamera.PITCH_LIMIT_DEG),
		deg_to_rad(PawnCamera.PITCH_LIMIT_DEG)
	)
	camera_rig.orthonormalize()


# Apply speed-scaled vertical headbob.
func _update_headbob(delta: float) -> void:
	var target_offset: float = 0.0
	if enable_headbob and game_state == GameState.ACTIVE and can_move() and run_speed > 0.01 \
			and not _movement_blocked and not _goal_reached:
		_headbob_phase = fmod(_headbob_phase + run_speed * headbob_steps_per_meter * TAU * delta, TAU)
		target_offset = sin(_headbob_phase) * headbob_amplitude
	var t: float = 1.0 if headbob_smoothing <= 0.0 else clamp(headbob_smoothing * delta, 0.0, 1.0)
	_headbob_offset = lerp(_headbob_offset, target_offset, t)
	if abs(_headbob_offset) < 0.0001 and is_zero_approx(target_offset):
		_headbob_offset = 0.0
	camera_rig.set_headbob_offset(_headbob_offset)


# Roll the camera toward the held shuffle direction. Only runs during shuffle
# or knockdown — outside those windows, lane lean owns rotation.z.
func _update_shuffle_camera_tilt(delta: float) -> void:
	if not _shuffle_active and not is_knocked_down():
		return
	var target_tilt: float = 0.0
	if _shuffle_active:
		target_tilt = -deg_to_rad(shuffle_camera_tilt_degrees) * float(_shuffle_camera_lean_direction)
	var tilt_delta: float = delta / maxf(Engine.time_scale, 0.001)
	var weight: float = 1.0 if shuffle_camera_tilt_speed <= 0.0 else clamp(shuffle_camera_tilt_speed * tilt_delta, 0.0, 1.0)
	camera_rig.rotation.z = lerp_angle(camera_rig.rotation.z, target_tilt, weight)
	if abs(camera_rig.rotation.z) < 0.001 and is_zero_approx(target_tilt):
		camera_rig.rotation.z = 0.0


# Roll the camera toward the held lane intent, then decay through the body
# tween via 1 - sqrt(t) so the lean follows through and uprights as the body
# settles. Spring-damper so it overshoots and bounces when underdamped.
func _update_lane_lean(delta: float) -> void:
	if _shuffle_active or is_knocked_down():
		_lane_lean_velocity = 0.0
		return
	var target_tilt: float = 0.0
	# Brain communicates held lane intent through lean(); we mirror it via
	# _shuffle_camera_lean_direction (which lean() also updates).
	if _shuffle_camera_lean_direction != 0:
		target_tilt = -deg_to_rad(lane_camera_tilt_degrees) * float(_shuffle_camera_lean_direction)
	elif _tween_active:
		var travel_dir: int = signi(float(_target_lane) - _tween_from)
		if travel_dir != 0:
			var raw: float = clampf(_tween_elapsed / maxf(lane_tween_duration, 0.001), 0.0, 1.0)
			var follow: float = 1.0 - sqrt(raw)
			target_tilt = -deg_to_rad(lane_camera_tilt_degrees) * float(travel_dir) * follow
	var current: float = camera_rig.rotation.z
	var damping: float = 2.0 * sqrt(lane_camera_tilt_stiffness) * lane_camera_tilt_damping_ratio
	var acceleration: float = lane_camera_tilt_stiffness * (target_tilt - current) - damping * _lane_lean_velocity
	_lane_lean_velocity += acceleration * delta
	var next: float = current + _lane_lean_velocity * delta
	if absf(_lane_lean_velocity) < 0.01 and absf(next - target_tilt) < 0.001:
		next = target_tilt
		_lane_lean_velocity = 0.0
	camera_rig.rotation.z = next
