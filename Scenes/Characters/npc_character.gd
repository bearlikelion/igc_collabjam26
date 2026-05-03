class_name NPCCharacter
extends CharacterBody3D

@export var walk_speed: float = 1.8
@export var sprint_speed: float = 3.5
@export var visual: CharacterVisual
@export var player_group: StringName = &"player"
@export var finish_group: StringName = &"finish"
@export var route_to_finish_point: bool = false
@export var arrival_distance: float = 0.5
@export var waypoint_skip_distance: float = 0.15
@export var shuffle_debug_enabled: bool = true

var desired_direction: Vector3 = Vector3.ZERO
var wants_sprint: bool = false
var route_target_position: Vector3 = Vector3.ZERO
var _has_target: bool = false
var _path_ready: bool = false
var _path_points: PackedVector3Array = PackedVector3Array()
var _path_index: int = 0
var _shuffle_direction: int = 0
var _shuffle_paused: bool = false
var _debug_label: Label3D
var _recovery_time_left: float = 0.0
var _get_up_time: float = 0.9
var _recover_started: bool = false
var _knockdown_active: bool = false

@onready var navigation_agent: NavigationAgent3D = $NavigationAgent3D


# Capture the route target and begin navigation.
func _ready() -> void:
	add_to_group("npc")
	_create_debug_label()
	navigation_agent.target_desired_distance = arrival_distance
	navigation_agent.path_desired_distance = arrival_distance
	_set_route_target.call_deferred()


# Follow the cached navigation path toward the selected route target.
func _physics_process(delta: float) -> void:
	if _knockdown_active:
		_update_knockdown_recovery(delta)
		return

	if _shuffle_paused:
		_stop_moving()
		return

	if not _has_target:
		_stop_moving()
		return

	if _has_arrived():
		queue_free()
		return

	_advance_path_index()
	var next_position: Vector3 = _get_current_path_target()
	var direction: Vector3 = next_position - global_position
	_move_in_direction(direction, delta)
	move_and_slide()
	_face_velocity()

	if visual != null:
		visual.set_move_speed(Vector2(velocity.x, velocity.z).length())
	_set_debug_text("MOVE\n%s" % _direction_name(_movement_direction()))


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
	desired_direction = Vector3.ZERO
	velocity = Vector3.ZERO
	if visual != null:
		visual.play_die()


# Pause navigation and telegraph a left or right shuffle.
func begin_subway_shuffle() -> int:
	_shuffle_paused = true
	_stop_moving()
	_shuffle_direction = -1 if randf() < 0.5 else 1
	if _shuffle_direction < 0:
		interact_left()
	else:
		interact_right()
	_set_debug_text("NPC %s" % _direction_name(_shuffle_direction))
	_debug_shuffle("TELEGRAPH %s" % _direction_name(_shuffle_direction))
	return _shuffle_direction


# Resume navigation after a successful shuffle.
func end_subway_shuffle() -> void:
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
	_stop_moving()
	_set_debug_text("STOP")
	_debug_shuffle("STOP")


# Knock the NPC away from the player and start its get-up sequence.
func knock_down_from_shuffle(player_position: Vector3, recovery_time: float, get_up_time: float, knockback_distance: float) -> void:
	_shuffle_paused = true
	_shuffle_direction = 0
	_recovery_time_left = maxf(recovery_time, get_up_time)
	_get_up_time = get_up_time
	_recover_started = false
	_knockdown_active = true
	_stop_moving()
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
	return route_to_finish_point


# Resolve the route target after the navigation map has registered.
func _set_route_target() -> void:
	await get_tree().physics_frame
	var target: Node3D = _find_route_target()
	if target == null:
		push_warning("NPCCharacter could not find a %s target." % _route_target_name())
		return
	route_target_position = target.global_position
	navigation_agent.target_position = route_target_position
	print("NPC Target Position (%s): %s" % [_route_target_name(), navigation_agent.target_position])
	_has_target = true
	await get_tree().physics_frame
	_cache_navigation_path()
	_path_ready = true


# Find the active route target.
func _find_route_target() -> Node3D:
	if route_to_finish_point:
		return _find_finish()
	return _find_player()


# Find the player from an explicit path, group, or scene-tree search.
func _find_player() -> Player:
	var grouped_node: Node = get_tree().get_first_node_in_group(player_group)
	if grouped_node is Player:
		return grouped_node as Player
	return null


# Find the finish marker by group.
func _find_finish() -> Node3D:
	var grouped_node: Node = get_tree().get_first_node_in_group(finish_group)
	if grouped_node is Node3D:
		return grouped_node as Node3D
	return null


# Apply horizontal velocity for a navigation direction.
func _move_in_direction(direction: Vector3, delta: float) -> void:
	direction.y = 0.0
	if direction.length_squared() <= 0.001:
		_stop_moving()
		return
	var distance: float = direction.length()
	direction = direction.normalized()
	desired_direction = direction
	var speed: float = sprint_speed if wants_sprint else walk_speed
	if distance < speed * delta:
		speed = distance / delta
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed


# Cache the current navigation path after the agent has synchronized.
func _cache_navigation_path() -> void:
	navigation_agent.get_next_path_position()
	_path_points = navigation_agent.get_current_navigation_path()
	_path_index = navigation_agent.get_current_navigation_path_index()
	_advance_path_index()
	if _path_points.is_empty():
		push_warning("NPCCharacter could not build a path to %s." % _route_target_name())
	else:
		_debug_shuffle("PATH points=%s target=%s" % [_path_points.size(), route_target_position])


# Move past waypoints already reached by the NPC.
func _advance_path_index() -> void:
	var skip_distance: float = maxf(waypoint_skip_distance, arrival_distance)
	while _path_index < _path_points.size():
		var waypoint_delta: Vector3 = _path_points[_path_index] - global_position
		waypoint_delta.y = 0.0
		if waypoint_delta.length() > skip_distance:
			return
		_path_index += 1


# Return the active path point or the final target as a fallback.
func _get_current_path_target() -> Vector3:
	if _path_index >= 0 and _path_index < _path_points.size():
		return _path_points[_path_index]
	return route_target_position


# Return whether the NPC has reached the selected route target.
func _has_arrived() -> bool:
	if not _path_ready:
		return false
	var flat_delta: Vector3 = route_target_position - global_position
	flat_delta.y = 0.0
	return flat_delta.length() <= arrival_distance


# Update the NPC knockdown/get-up timer.
func _update_knockdown_recovery(delta: float) -> void:
	_stop_moving()
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


# Resume navigation after knockdown recovery.
func _finish_knockdown_recovery() -> void:
	_recover_started = false
	_knockdown_active = false
	_shuffle_paused = false
	if visual != null:
		visual.play_walk()
	navigation_agent.target_position = route_target_position
	_cache_navigation_path()
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


# Stop horizontal movement.
func _stop_moving() -> void:
	desired_direction = Vector3.ZERO
	velocity.x = 0.0
	velocity.z = 0.0


# Turn the NPC toward its current travel direction.
func _face_velocity() -> void:
	var horizontal_velocity: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	if horizontal_velocity.length_squared() <= 0.001:
		return
	rotation.y = atan2(-horizontal_velocity.x, -horizontal_velocity.z)


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


# Return the NPC's current dominant movement direction.
func _movement_direction() -> int:
	if abs(velocity.x) > abs(velocity.z):
		return -1 if velocity.x < 0.0 else 1
	return 0


# Return the selected route target name for debug output.
func _route_target_name() -> String:
	return "finish" if route_to_finish_point else "player spawn"


# Return a readable direction label.
func _direction_name(direction: int) -> String:
	if direction < 0:
		return "LEFT"
	if direction > 0:
		return "RIGHT"
	return "FORWARD"
