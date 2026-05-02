class_name MovementTest
extends Node3D

# Drives the player parametrically along nav path segments.
#
# Each segment has: start point, end point, forward direction, length.
# Player position = segment.start + forward * distance + right * lane_offset
# Distance increments at run_speed each frame.
# When distance >= segment length (adjusted for lane), advance to next segment.
#
# Lane is a fixed perpendicular offset:
#   Lane 0 (left)   = -1.0 perpendicular
#   Lane 1 (center) =  0.0
#   Lane 2 (right)  = +1.0 perpendicular
#
# Segment length per lane:
#   The end of a segment is the corner point. To reach the L tile (outer),
#   the left lane needs to travel longer along the incoming straight, then
#   takes a shorter outgoing segment. We compute per-lane segment lengths
#   so each lane reaches the center of its L/M/R tile before turning.

const LANE_OFFSETS: Array[float] = [-1.0, 0.0, 1.0]
const CORNER_ANGLE_THRESHOLD: float = 0.95

# Debug visualization
@export var debug_show_corners: bool = true
@export var debug_corner_color: Color = Color(1.0, 0.2, 0.2, 0.7)
@export var debug_lane_color: Color = Color(0.2, 1.0, 0.2, 0.5)
@export var debug_corner_radius: float = 0.5

@onready var _player: Player = %Player
@onready var _finish: Marker3D = %Finish

var _ready_state: bool = false
var _corners: Array[Vector3] = []
var _segment_index: int = 0
var _distance_along: float = 0.0


func _ready() -> void:
	_player.lane_changed.connect(_on_lane_changed)
	_wait_for_nav.call_deferred()


func _wait_for_nav() -> void:
	print("Wait for nav")
	var params: NavigationPathQueryParameters3D = NavigationPathQueryParameters3D.new()
	var result: NavigationPathQueryResult3D = NavigationPathQueryResult3D.new()
	while true:
		await get_tree().physics_frame
		params.map = get_world_3d().navigation_map
		params.start_position = _player.global_position
		params.target_position = _finish.global_position
		NavigationServer3D.query_path(params, result)
		if result.path.size() >= 2:
			break
	_corners = _simplify_path(result.path)
	_corners = _snap_to_axes(_corners)
	_corners = _collapse_short_segments(_corners)
	print("=== CORNERS (%s) ===" % _corners.size())
	for i: int in range(_corners.size()):
		print("  [%s] %s" % [i, _corners[i]])
	if debug_show_corners:
		_spawn_debug_markers()
	_ready_state = true


# Spawn visible markers at each corner and along each lane path.
# Lives under a "_DebugMarkers" child node, easy to delete.
func _spawn_debug_markers() -> void:
	var root: Node3D = Node3D.new()
	root.name = "_DebugMarkers"
	add_child(root)

	# Sphere mesh and material reused for all corner markers.
	var corner_mat: StandardMaterial3D = StandardMaterial3D.new()
	corner_mat.albedo_color = debug_corner_color
	corner_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	corner_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	corner_mat.no_depth_test = true

	var sphere: SphereMesh = SphereMesh.new()
	sphere.radius = debug_corner_radius
	sphere.height = debug_corner_radius * 2.0
	sphere.material = corner_mat

	for i: int in range(_corners.size()):
		var marker: MeshInstance3D = MeshInstance3D.new()
		marker.mesh = sphere
		marker.global_position = _corners[i]
		marker.name = "Corner_%s" % i
		root.add_child(marker)

	# Draw the path lines between corners using ImmediateMesh-style line meshes.
	for i: int in range(_corners.size() - 1):
		var line: MeshInstance3D = _make_line(_corners[i], _corners[i + 1], debug_corner_color)
		line.name = "Path_%s" % i
		root.add_child(line)

	# Per-lane path lines offset perpendicular.
	for lane: int in range(LANE_OFFSETS.size()):
		var lane_color: Color = debug_lane_color
		lane_color.a = 0.6
		for i: int in range(_corners.size() - 1):
			var seg_start: Vector3 = _corners[i]
			var seg_end: Vector3 = _corners[i + 1]
			var seg_dir: Vector3 = (seg_end - seg_start)
			seg_dir.y = 0.0
			seg_dir = seg_dir.normalized()
			var right: Vector3 = seg_dir.cross(Vector3.UP).normalized()
			var offset: Vector3 = right * LANE_OFFSETS[lane]
			var lane_line: MeshInstance3D = _make_line(seg_start + offset, seg_end + offset, lane_color)
			lane_line.name = "Lane_%s_Path_%s" % [lane, i]
			root.add_child(lane_line)


func _make_line(from: Vector3, to: Vector3, color: Color) -> MeshInstance3D:
	var im: ImmediateMesh = ImmediateMesh.new()
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	im.surface_add_vertex(from)
	im.surface_add_vertex(to)
	im.surface_end()
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = im
	return mi


# Snap corner positions so each segment is perfectly axis-aligned (X or Z only).
# When a raw segment changes BOTH X and Z significantly, it's an L-bend the nav
# took diagonally — we insert an intermediate corner to make two axis-aligned
# segments instead.
func _snap_to_axes(corners: Array[Vector3]) -> Array[Vector3]:
	if corners.size() < 2:
		return corners
	var result: Array[Vector3] = []
	result.append(corners[0])
	const AXIS_TOLERANCE: float = 0.5

	for i: int in range(1, corners.size()):
		var prev: Vector3 = result[result.size() - 1]
		var curr: Vector3 = corners[i]
		var dx: float = abs(curr.x - prev.x)
		var dz: float = abs(curr.z - prev.z)

		if dx > AXIS_TOLERANCE and dz > AXIS_TOLERANCE:
			# Diagonal segment — insert an L-bend corner.
			# Choose the dominant axis to travel first along.
			var bend: Vector3
			if dz > dx:
				# Travel along Z first, then X.
				bend = Vector3(prev.x, prev.y, curr.z)
			else:
				# Travel along X first, then Z.
				bend = Vector3(curr.x, prev.y, prev.z)
			result.append(bend)
			# Only add the curr point if it's meaningfully past the bend.
			if (curr - bend).length() > AXIS_TOLERANCE:
				result.append(curr)
		elif dx > dz:
			# Pure X segment — snap Z to previous.
			result.append(Vector3(curr.x, curr.y, prev.z))
		else:
			# Pure Z segment — snap X to previous.
			result.append(Vector3(prev.x, curr.y, curr.z))
	return result


func _simplify_path(path: PackedVector3Array) -> Array[Vector3]:
	var result: Array[Vector3] = []
	result.append(path[0])
	for i: int in range(1, path.size() - 1):
		var prev_dir: Vector3 = (path[i] - path[i - 1])
		var next_dir: Vector3 = (path[i + 1] - path[i])
		prev_dir.y = 0.0
		next_dir.y = 0.0
		if prev_dir.length_squared() < 0.001 or next_dir.length_squared() < 0.001:
			continue
		if prev_dir.normalized().dot(next_dir.normalized()) < CORNER_ANGLE_THRESHOLD:
			result.append(path[i])
	result.append(path[path.size() - 1])
	return result


# Drop intermediate corners where two consecutive segments are very short or
# nearly collinear after axis snapping.
func _collapse_short_segments(corners: Array[Vector3]) -> Array[Vector3]:
	if corners.size() < 3:
		return corners
	const MIN_SEG: float = 2.0
	var result: Array[Vector3] = [corners[0]]
	for i: int in range(1, corners.size() - 1):
		var prev: Vector3 = result[result.size() - 1]
		var curr: Vector3 = corners[i]
		var nxt: Vector3 = corners[i + 1]
		var seg_len: float = (curr - prev).length()
		# Skip this corner if the segment leading into it is too short.
		if seg_len < MIN_SEG:
			continue
		# Skip if removing it leaves a pure axis-aligned segment to the next.
		var after: Vector3 = nxt - curr
		var before: Vector3 = curr - prev
		before.y = 0.0
		after.y = 0.0
		if before.length_squared() > 0.001 and after.length_squared() > 0.001:
			if before.normalized().dot(after.normalized()) > 0.99:
				continue
		result.append(curr)
	result.append(corners[corners.size() - 1])
	return result


func _on_lane_changed() -> void:
	# When the lane changes, snap player position immediately to the new lane
	# at the same distance along the current segment.
	_apply_position()


func _physics_process(delta: float) -> void:
	if not _ready_state:
		return
	if _segment_index >= _corners.size() - 1:
		return

	# Advance distance along current segment.
	_distance_along += _player.run_speed * delta

	var seg_length: float = _get_segment_length()
	if _distance_along >= seg_length:
		# Reached the end of this segment — advance to the next one.
		_segment_index += 1
		_distance_along = 0.0
		print("ADVANCE to segment %s" % _segment_index)
		if _segment_index >= _corners.size() - 1:
			print("REACHED DESTINATION at %s" % _player.global_position)
			return

	_apply_position()
	_apply_yaw(delta)


# Compute the player's current position from segment + distance + lane.
func _apply_position() -> void:
	if _segment_index >= _corners.size() - 1:
		return
	var seg_start: Vector3 = _corners[_segment_index]
	var seg_end: Vector3 = _corners[_segment_index + 1]
	var seg_dir: Vector3 = (seg_end - seg_start)
	seg_dir.y = 0.0
	seg_dir = seg_dir.normalized()
	var right: Vector3 = seg_dir.cross(Vector3.UP).normalized()
	var lane_offset: float = LANE_OFFSETS[_player._current_lane]

	var pos: Vector3 = seg_start + seg_dir * _distance_along + right * lane_offset
	pos.y = _player.global_position.y
	_player.global_position = pos


# Compute the per-lane segment length so each lane reaches its L/M/R tile.
# The corner point is shared; the lane offset shifts when we cross the corner,
# so the effective travel for the outer lane along the incoming segment is
# longer by abs(lane_offset).
func _get_segment_length() -> float:
	var seg_start: Vector3 = _corners[_segment_index]
	var seg_end: Vector3 = _corners[_segment_index + 1]
	var seg: Vector3 = seg_end - seg_start
	seg.y = 0.0
	var base_length: float = seg.length()

	# If this is the last segment, just use base length (lane offset already applied at start).
	if _segment_index >= _corners.size() - 2:
		return base_length

	# Otherwise, adjust for the next segment's turn direction.
	# The outer lane (relative to the turn) needs to travel further.
	var seg_dir: Vector3 = seg.normalized()
	var next_start: Vector3 = _corners[_segment_index + 1]
	var next_end: Vector3 = _corners[_segment_index + 2]
	var next_dir: Vector3 = next_end - next_start
	next_dir.y = 0.0
	next_dir = next_dir.normalized()

	# Right axis of CURRENT segment.
	var right: Vector3 = seg_dir.cross(Vector3.UP).normalized()
	# Sign of the turn: positive if next_dir is to the right of current, negative if left.
	var turn_sign: float = sign(right.dot(next_dir))

	var lane_offset: float = LANE_OFFSETS[_player._current_lane]
	# Outer lane (opposite sign from turn) extends segment length by |offset|.
	# Inner lane (same sign as turn) shortens segment length by |offset|.
	var length_adjust: float = -lane_offset * turn_sign
	return base_length + length_adjust


func _apply_yaw(delta: float) -> void:
	var seg_start: Vector3 = _corners[_segment_index]
	var seg_end: Vector3 = _corners[_segment_index + 1]
	var fwd: Vector3 = seg_end - seg_start
	fwd.y = 0.0
	if fwd.length_squared() < 0.001:
		return
	fwd = fwd.normalized()
	var target_yaw: float = atan2(-fwd.x, -fwd.z)
	var turn_weight: float = clamp(10.0 * delta, 0.0, 1.0)
	_player.rotation.y = lerp_angle(_player.rotation.y, target_yaw, turn_weight)
