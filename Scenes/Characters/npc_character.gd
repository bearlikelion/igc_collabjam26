class_name NPCCharacter
extends CharacterBody3D

# Rail direction constants. Forward runs Start -> Finish (player direction);
# reverse runs Finish -> Start (oncoming traffic).
enum RailDirection { FORWARD, REVERSE }

const LANE_COUNT: int = 3

@export var visual: CharacterVisual
@export var player_group: StringName = &"player"
@export var finish_group: StringName = &"finish"

@export_group("Rail")
## Direction of travel along the lane rail.
@export var rail_direction: RailDirection = RailDirection.REVERSE
## Initial distance along the rail. Authored per-instance.
@export var rail_start_distance: float = 0.0
## Forward speed along the rail.
@export var rail_speed: float = 1.8
## Multiplicative jitter applied once on spawn so NPCs don't form a wall.
## A value of 0.3 means rail_speed is randomized in [0.7 * rail_speed, 1.3 * rail_speed].
@export_range(0.0, 1.0, 0.01) var rail_speed_variance: float = 0.3

@export_group("Lane Behavior")
## Steer around chair benches and other obstacles by switching lanes.
@export var avoid_obstacles: bool = true
## Distance ahead checked when deciding to swerve away from an obstacle.
@export var obstacle_lookahead: float = 2.5
## Periodically pick a new random lane while traveling.
@export var random_lane_changes: bool = false
## Average seconds between random lane change attempts.
@export var random_lane_interval_min: float = 3.0
@export var random_lane_interval_max: float = 7.0
## Seconds to wait after an avoidance lane change before swerving again.
@export var avoidance_cooldown: float = 0.6

@export_group("Subway Shuffle")
@export var shuffle_debug_enabled: bool = true
@export var shuffle_lane_distance: float = 1.0
@export var shuffle_lane_move_time: float = 0.25

var _current_lane: int = 1
var _actual_rail_speed: float = 0.0
var _shuffle_direction: int = 0
var _shuffle_paused: bool = false
var _debug_label: Label3D
var _recovery_time_left: float = 0.0
var _get_up_time: float = 0.9
var _recover_started: bool = false
var _knockdown_active: bool = false
var _shuffle_lane_move_active: bool = false
var _shuffle_lane_start_position: Vector3 = Vector3.ZERO
var _shuffle_lane_target_position: Vector3 = Vector3.ZERO
var _shuffle_lane_elapsed: float = 0.0
var _random_lane_timer: float = 0.0
var _avoidance_timer: float = 0.0
var _parked_at_finish: bool = false
var _parked_offset: Vector3 = Vector3.ZERO

@onready var _shuffle_cast: RayCast3D = get_node_or_null("ShuffleCast")


# Pick an initial lane and randomize the first lane-change timer.
func _ready() -> void:
	add_to_group("npc")
	_create_debug_label()
	_current_lane = randi() % LANE_COUNT
	_random_lane_timer = _next_random_lane_delay()
	_roll_actual_rail_speed()


# Tick down lane-change timers; the rail controller drives forward motion.
func _physics_process(delta: float) -> void:
	if _knockdown_active:
		_update_knockdown_recovery(delta)
		return
	if _shuffle_paused:
		_update_shuffle_lane_move(delta)
		return
	if _avoidance_timer > 0.0:
		_avoidance_timer = maxf(0.0, _avoidance_timer - delta)
	else:
		_check_avoidance_cast()
	if random_lane_changes:
		_random_lane_timer -= delta
		if _random_lane_timer <= 0.0:
			_random_lane_timer = _next_random_lane_delay()
			_attempt_random_lane_change()


# Return the lane the rail controller should use for this NPC.
func get_current_lane() -> int:
	return _current_lane


# Set the lane directly; the rail controller will snap our position next frame.
func set_current_lane(lane: int) -> void:
	_current_lane = clampi(lane, 0, LANE_COUNT - 1)


# Return whether the rail controller should stop advancing this NPC.
func is_runner_paused() -> bool:
	return _shuffle_paused or _knockdown_active


# Return the rail direction for this NPC.
func get_rail_direction() -> int:
	return rail_direction


# Return the authored starting distance along the rail.
func get_rail_start_distance() -> float:
	return rail_start_distance


# Park the NPC at the finish: pause its animation and record an offset the
# rail controller can apply to keep it off the player's lane line.
func park_at_finish(offset: Vector3) -> void:
	_parked_at_finish = true
	_parked_offset = offset
	if visual != null:
		visual.pause_animation()


# Return whether this NPC has been parked at the finish.
func is_parked_at_finish() -> bool:
	return _parked_at_finish


# Return the loiter offset to apply on top of the rail position when parked.
func get_parked_offset() -> Vector3:
	return _parked_offset


# Return the rail forward speed (with per-instance jitter applied at spawn).
func get_rail_speed() -> float:
	if _actual_rail_speed <= 0.0:
		_roll_actual_rail_speed()
	return _actual_rail_speed


# Roll a randomized rail speed within +/- rail_speed_variance of the base.
func _roll_actual_rail_speed() -> void:
	var jitter: float = (randf() * 2.0 - 1.0) * rail_speed_variance
	_actual_rail_speed = maxf(0.1, rail_speed * (1.0 + jitter))


# Return whether obstacle avoidance is enabled.
func should_avoid_obstacles() -> bool:
	return avoid_obstacles


# Return the planning lookahead distance for swerving.
func get_obstacle_lookahead() -> float:
	return obstacle_lookahead


# Play a left-side interaction animation.
func interact_left() -> void:
	if visual != null:
		visual.play_interact_left()


# Play a right-side interaction animation.
func interact_right() -> void:
	if visual != null:
		visual.play_interact_right()


# Play the death animation and stop movement.
func die() -> void:
	velocity = Vector3.ZERO
	if visual != null:
		visual.play_die()


# Pause rail movement and telegraph a left or right shuffle.
func begin_subway_shuffle() -> int:
	_shuffle_paused = true
	_shuffle_direction = -1 if randf() < 0.5 else 1
	if _shuffle_direction < 0:
		interact_left()
	else:
		interact_right()
	_set_debug_text("NPC %s" % _direction_name(_shuffle_direction))
	_debug_shuffle("TELEGRAPH %s" % _direction_name(_shuffle_direction))
	return _shuffle_direction


# Resume rail movement after a successful shuffle.
func end_subway_shuffle() -> void:
	_start_shuffle_lane_move(_shuffle_direction)
	_finish_shuffle_lane_move()
	_shuffle_paused = false
	_shuffle_direction = 0
	if visual != null:
		visual.play_walk()
	_set_debug_text("MOVE")
	_debug_shuffle("RESUME")


# Clear shuffle state without resuming movement.
func stop_subway_shuffle() -> void:
	_shuffle_paused = true
	_shuffle_direction = 0
	_shuffle_lane_move_active = false
	_set_debug_text("STOP")
	_debug_shuffle("STOP")


# Knock the NPC away from the player and start its get-up sequence.
func knock_down_from_shuffle(player_position: Vector3, recovery_time: float, get_up_time: float, knockback_distance: float) -> void:
	_shuffle_paused = true
	_shuffle_direction = 0
	_shuffle_lane_move_active = false
	_recovery_time_left = maxf(recovery_time, get_up_time)
	_get_up_time = get_up_time
	_recover_started = false
	_knockdown_active = true
	_apply_knockback_from(player_position, knockback_distance)
	if visual != null:
		visual.play_die()
	_set_debug_text("KNOCKDOWN")
	_debug_shuffle("KNOCKDOWN recovery=%.2f" % _recovery_time_left)


# Return the active telegraphed shuffle direction.
func get_shuffle_direction() -> int:
	return _shuffle_direction


# Return whether this NPC is routing in the same direction as the player.
func is_routing_to_finish_point() -> bool:
	return rail_direction == RailDirection.FORWARD


# Update the NPC knockdown/get-up timer.
func _update_knockdown_recovery(delta: float) -> void:
	if _recovery_time_left > 0.0:
		_recovery_time_left = maxf(0.0, _recovery_time_left - delta)
	_set_debug_text("NPC RECOVER\n%.2f" % _recovery_time_left)
	if not _recover_started and _recovery_time_left <= _get_up_time and _can_start_knockdown_get_up():
		_recover_started = true
		if visual != null:
			visual.play_recover()
		_debug_shuffle("GET UP")
	if _recovery_time_left <= 0.0 and _recover_started and _can_finish_knockdown_recovery():
		_finish_knockdown_recovery()


# Return whether die playback is finished and get-up can begin.
func _can_start_knockdown_get_up() -> bool:
	return visual == null or visual.can_start_recover()


# Return whether the recover animation has finished owning NPC visuals.
func _can_finish_knockdown_recovery() -> bool:
	return visual == null or not visual.is_recovery_locked()


# Resume rail movement after knockdown recovery.
func _finish_knockdown_recovery() -> void:
	_recover_started = false
	_knockdown_active = false
	_shuffle_paused = false
	if visual != null:
		visual.play_walk()
	_set_debug_text("MOVE")
	_debug_shuffle("RECOVERED")


# Push the NPC away from the player collision point.
func _apply_knockback_from(player_position: Vector3, knockback_distance: float) -> void:
	var direction: Vector3 = global_position - player_position
	direction.y = 0.0
	if direction.length_squared() <= 0.001:
		direction = global_transform.basis.z
		direction.y = 0.0
	if direction.length_squared() <= 0.001:
		direction = Vector3.BACK
	direction = direction.normalized()
	global_position += direction * knockback_distance


# Start moving the NPC toward the side it chose for the shuffle.
func _start_shuffle_lane_move(direction: int) -> void:
	var lane_direction: Vector3 = global_transform.basis.x * float(direction)
	lane_direction.y = 0.0
	if lane_direction.length_squared() <= 0.001 or is_zero_approx(shuffle_lane_distance):
		_shuffle_lane_move_active = false
		return
	_shuffle_lane_start_position = global_position
	_shuffle_lane_target_position = global_position + lane_direction.normalized() * shuffle_lane_distance
	_shuffle_lane_elapsed = 0.0
	_shuffle_lane_move_active = true


# Move across to the selected shuffle lane using real-time duration.
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


# Finish the selected lane move before returning to navigation.
func _finish_shuffle_lane_move() -> void:
	if not _shuffle_lane_move_active:
		return
	_shuffle_lane_move_active = false
	_shuffle_lane_target_position.y = global_position.y
	global_position = _shuffle_lane_target_position


# Swerve to a different lane when the forward cast sees another character.
# NPCs swerve away from any other NPC and from a knocked-down player, but
# they keep their lane against an active player so the dodge mechanic still
# triggers normally.
func _check_avoidance_cast() -> void:
	if _shuffle_cast == null:
		return
	_shuffle_cast.force_raycast_update()
	if not _shuffle_cast.is_colliding():
		return
	var collider: Object = _shuffle_cast.get_collider()
	if not (collider is Node):
		return
	var node: Node = collider as Node
	if node == self:
		return
	var should_swerve: bool = false
	if node.is_in_group("npc"):
		should_swerve = true
	elif node.is_in_group(player_group):
		# Only swerve around the player when they can't react (knocked down).
		var player_node: Player = node as Player
		should_swerve = player_node != null and player_node.is_runner_paused()
	if not should_swerve:
		return
	if _attempt_random_lane_change():
		_avoidance_timer = avoidance_cooldown
		_debug_shuffle("AVOIDANCE -> lane %s" % _current_lane)


# Pick a random lane different from the current lane. Returns true if the
# lane actually changed so callers can gate cooldowns on a real swap.
func _attempt_random_lane_change() -> bool:
	if LANE_COUNT <= 1:
		return false
	var choices: Array[int] = []
	for lane: int in range(LANE_COUNT):
		if lane != _current_lane:
			choices.append(lane)
	if choices.is_empty():
		return false
	_current_lane = choices[randi() % choices.size()]
	_debug_shuffle("RANDOM LANE -> %s" % _current_lane)
	return true


# Return a randomized delay before the next lane change attempt.
func _next_random_lane_delay() -> float:
	var lo: float = minf(random_lane_interval_min, random_lane_interval_max)
	var hi: float = maxf(random_lane_interval_min, random_lane_interval_max)
	if hi <= 0.0:
		return 1.0
	return lo + randf() * maxf(hi - lo, 0.0)


# Create a visible debug label above the NPC.
func _create_debug_label() -> void:
	if not shuffle_debug_enabled or _debug_label != null:
		return
	_debug_label = Label3D.new()
	_debug_label.name = "NPCDebugLabel"
	_debug_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_debug_label.no_depth_test = true
	_debug_label.font_size = 32
	_debug_label.modulate = Color(1.0, 0.8, 0.15, 1.0)
	_debug_label.position = Vector3(0.0, 2.4, 0.0)
	add_child(_debug_label)


# Update the visible NPC debug label.
func _set_debug_text(text: String) -> void:
	if not shuffle_debug_enabled:
		return
	_create_debug_label()
	if _debug_label != null:
		_debug_label.text = text


# Print NPC shuffle debug messages.
func _debug_shuffle(message: String) -> void:
	if shuffle_debug_enabled:
		print("[Shuffle][NPC:%s] %s" % [name, message])


# Return a readable direction label.
func _direction_name(direction: int) -> String:
	if direction < 0:
		return "LEFT"
	if direction > 0:
		return "RIGHT"
	return "FORWARD"
