class_name MovementTest
extends Node3D

# Wires the Player to a NavigationAgent3D that pathfinds to Finish.
# The player's current lane shifts the lateral offset perpendicular to the
# path direction, so outer-lane players commit to a corner later than
# inner-lane players — matching real racing-line geometry.
#
# Camera yaw tracks the PATH segment direction only — never the lateral
# lane-change offset — so switching lanes never moves the camera.

@onready var _player: Player = $Player
@onready var _finish: Marker3D = $Finish

var _agent: NavigationAgent3D
# The path-segment forward direction, updated only when the nav path changes.
var _path_forward: Vector3 = Vector3(0.0, 0.0, -1.0)


func _ready() -> void:
	_agent = _player.navigation_agent
	_agent.path_desired_distance = 0.4
	_agent.target_desired_distance = 0.8
	_agent.avoidance_enabled = false
	_agent.debug_enabled = true
	_agent.debug_use_custom = false

	_agent.velocity_computed.connect(_on_velocity_computed)
	_agent.navigation_finished.connect(_on_navigation_finished)

	await get_tree().physics_frame
	_agent.target_position = _finish.global_position


func _physics_process(delta: float) -> void:
	if _agent.is_navigation_finished():
		return

	# Update the lane-offset target every frame so the nav path reflects
	# which side of the corridor the player is currently running in.
	var right: Vector3 = _path_forward.cross(Vector3.UP).normalized()
	var lane_offset: float = _lane_to_offset(_player._current_lane)
	_agent.target_position = _finish.global_position + right * lane_offset

	# Derive path forward purely from the nav path points, not player→waypoint.
	# This means lane changes (X movement) never affect the yaw.
	var path: PackedVector3Array = _agent.get_current_navigation_path()
	var path_seg_forward: Vector3 = _get_path_segment_forward(path)
	if path_seg_forward != Vector3.ZERO:
		_path_forward = path_seg_forward

	# Rotate body yaw toward path forward direction only.
	var target_yaw: float = atan2(-_path_forward.x, -_path_forward.z)
	var turn_weight: float = clamp(6.0 * delta, 0.0, 1.0)
	_player.rotation.y = lerp_angle(_player.rotation.y, target_yaw, turn_weight)


# Walk the path points to find the forward direction of the segment the
# player is currently on, ignoring any lateral offset.
func _get_path_segment_forward(path: PackedVector3Array) -> Vector3:
	if path.size() < 2:
		return Vector3.ZERO

	var player_pos: Vector3 = _player.global_position
	var closest_dist: float = INF
	var best_dir: Vector3 = Vector3.ZERO

	for i: int in range(path.size() - 1):
		var a: Vector3 = path[i]
		var b: Vector3 = path[i + 1]
		a.y = 0.0
		b.y = 0.0
		var seg: Vector3 = b - a
		if seg.length_squared() < 0.001:
			continue
		# Project player onto segment to find closest point.
		var flat_pos: Vector3 = Vector3(player_pos.x, 0.0, player_pos.z)
		var t: float = clamp((flat_pos - a).dot(seg.normalized()) / seg.length(), 0.0, 1.0)
		var closest: Vector3 = a + seg.normalized() * t * seg.length()
		var dist: float = (flat_pos - closest).length()
		if dist < closest_dist:
			closest_dist = dist
			best_dir = seg.normalized()

	return best_dir


func _on_velocity_computed(_safe_velocity: Vector3) -> void:
	pass


func _on_navigation_finished() -> void:
	print("REACHED DESTINATION")


func _lane_to_offset(lane: int) -> float:
	match lane:
		0:
			return -1.0
		2:
			return 1.0
		_:
			return 0.0
