class_name NPCCharacter
extends CharacterBody3D

@export var walk_speed: float = 1.8
@export var sprint_speed: float = 3.5
@export var visual: CharacterVisual
@export var player_group: StringName = &"player"
@export var arrival_distance: float = 0.5
@export var waypoint_skip_distance: float = 0.15

var desired_direction: Vector3 = Vector3.ZERO
var wants_sprint: bool = false
var player_spawn_position: Vector3 = Vector3.ZERO
var _has_target: bool = false
var _path_ready: bool = false
var _path_points: PackedVector3Array = PackedVector3Array()
var _path_index: int = 0

@onready var navigation_agent: NavigationAgent3D = $NavigationAgent3D


# Capture the player's start position and begin navigation.
func _ready() -> void:
	add_to_group("npc")
	navigation_agent.target_desired_distance = arrival_distance
	navigation_agent.path_desired_distance = arrival_distance
	_set_target_from_player.call_deferred()


# Follow the cached navigation path toward the captured player spawn position.
func _physics_process(delta: float) -> void:
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


# Resolve the player node after the navigation map has registered.
func _set_target_from_player() -> void:
	await get_tree().physics_frame
	var player: Player = _find_player()
	if player == null:
		push_warning("NPCCharacter could not find a player target.")
		return
	player_spawn_position = player.global_position
	navigation_agent.target_position = player_spawn_position
	print("NPC Target Position: %s" % navigation_agent.target_position)
	_has_target = true
	await get_tree().physics_frame
	_cache_navigation_path()
	_path_ready = true


# Find the player from an explicit path, group, or scene-tree search.
func _find_player() -> Player:
	var grouped_node: Node = get_tree().get_first_node_in_group(player_group)
	if grouped_node is Player:
		return grouped_node as Player
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
		push_warning("NPCCharacter could not build a path to the player spawn.")


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
	return player_spawn_position


# Return whether the NPC has reached the captured spawn target.
func _has_arrived() -> bool:
	if not _path_ready:
		return false
	var flat_delta: Vector3 = player_spawn_position - global_position
	flat_delta.y = 0.0
	return flat_delta.length() <= arrival_distance


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
