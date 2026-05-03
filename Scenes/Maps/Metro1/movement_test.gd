@tool
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
## Toggle in the editor to rebuild debug markers from the current nav mesh.
@export var refresh_debug: bool = false:
	set(value):
		refresh_debug = false
		if Engine.is_editor_hint():
			_editor_rebuild_debug()

@onready var _player: Player = %Player
@onready var _finish: Marker3D = %Finish

var _ready_state: bool = false
var _corners: Array[Vector3] = []
var _segment_index: int = 0
var _distance_along: float = 0.0


func _ready() -> void:
	if Engine.is_editor_hint():
		return
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
	_corners = _center_corners_on_corridor(_corners, get_world_3d().navigation_map)
	_corners = _snap_to_axes(_corners)
	_corners = _merge_close_corners(_corners)
	_pin_path_endpoints(_player.global_position, _finish.global_position)
	_corners = _orthogonalize_preserving_endpoints(_corners)
	print("=== CORNERS (%s) ===" % _corners.size())
	for i: int in range(_corners.size()):
		print("  [%s] %s" % [i, _corners[i]])
	if debug_show_corners:
		_spawn_debug_markers()
	_ready_state = true


# Spawn visible markers at each corner and along each lane path.
# Lives under a "_DebugMarkers" child node, easy to delete.
func _spawn_debug_markers() -> void:
	# Remove any prior debug node so we can rebuild cleanly.
	var existing: Node = get_node_or_null("DebugMarkers")
	if existing != null:
		existing.queue_free()
	var root: Node3D = Node3D.new()
	root.name = "DebugMarkers"
	# Don't serialize the debug tree into the scene file.
	add_child(root)
	root.owner = null

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
		marker.name = "Corner_%s" % i
		root.add_child(marker)
		marker.global_position = _corners[i]

	# Draw the path lines between corners using ImmediateMesh-style line meshes.
	for i: int in range(_corners.size() - 1):
		var line: MeshInstance3D = _make_line(_corners[i], _corners[i + 1], debug_corner_color)
		line.name = "Path_%s" % i
		root.add_child(line)

	# Per-lane path lines use lane-specific turn points.
	for lane: int in range(LANE_OFFSETS.size()):
		var lane_color: Color = debug_lane_color
		lane_color.a = 0.6
		for i: int in range(_corners.size() - 1):
			var lane_line: MeshInstance3D = _make_line(
				_get_lane_segment_start(i, lane),
				_get_lane_segment_end(i, lane),
				lane_color
			)
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
	const DIAGONAL_TURN_RATIO: float = 0.35

	for i: int in range(1, corners.size()):
		var prev: Vector3 = result[result.size() - 1]
		var curr: Vector3 = corners[i]
		var dx: float = abs(curr.x - prev.x)
		var dz: float = abs(curr.z - prev.z)
		var largest_axis: float = max(dx, dz)
		var smallest_axis: float = min(dx, dz)
		var diagonal_ratio: float = 0.0
		if largest_axis > 0.001:
			diagonal_ratio = smallest_axis / largest_axis

		if dx > AXIS_TOLERANCE and dz > AXIS_TOLERANCE and diagonal_ratio >= DIAGONAL_TURN_RATIO:
			# Balanced diagonal segment — insert an L-bend corner.
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


# Shift each interior corner toward the corridor center.
# The nav mesh path hugs inner walls; we want corners at the M (center) tile.
# Algorithm: at each corner, walk perpendicular to BOTH segments (the bisector
# of their two right-vectors) and find the corridor centerline using the
# navigation map's polygon edges via map_get_closest_point.
func _center_corners_on_corridor(corners: Array[Vector3], map_rid: RID) -> Array[Vector3]:
	if corners.size() < 3:
		return corners
	var result: Array[Vector3] = []
	result.append(corners[0])

	for i: int in range(1, corners.size() - 1):
		var prev: Vector3 = corners[i - 1]
		var curr: Vector3 = corners[i]
		var nxt: Vector3 = corners[i + 1]

		var in_dir: Vector3 = curr - prev
		var out_dir: Vector3 = nxt - curr
		in_dir.y = 0.0
		out_dir.y = 0.0
		var in_length: float = in_dir.length()
		var out_length: float = out_dir.length()
		if in_length < 0.001 or out_length < 0.001:
			result.append(curr)
			continue
		in_dir = in_dir.normalized()
		out_dir = out_dir.normalized()

		var in_perp: Vector3 = in_dir.cross(Vector3.UP).normalized()
		var out_perp: Vector3 = out_dir.cross(Vector3.UP).normalized()

		# Sample inside each neighboring segment. Short final legs can be less than
		# 2m, so clamp the sample distance to avoid centering from outside the corridor.
		var in_sample_distance: float = min(2.0, max(0.25, in_length * 0.5))
		var out_sample_distance: float = min(2.0, max(0.25, out_length * 0.5))
		var in_sample: Vector3 = curr - in_dir * in_sample_distance
		var in_centered: Vector3 = _center_on_axis(in_sample, in_perp, map_rid)
		var out_sample: Vector3 = curr + out_dir * out_sample_distance
		var out_centered: Vector3 = _center_on_axis(out_sample, out_perp, map_rid)

		# Corner is the intersection of the two centerlines.
		# Incoming centerline = in_centered + t * in_dir
		# Outgoing centerline = out_centered + s * out_dir
		# Solve for the intersection in XZ plane.
		var centered: Vector3 = _intersect_lines_xz(in_centered, in_dir, out_centered, out_dir)
		centered.y = curr.y
		result.append(centered)

	result.append(corners[corners.size() - 1])
	return result


# Find the XZ intersection of two infinite lines (each defined by point + direction).
# If parallel, returns the midpoint of the two points.
func _intersect_lines_xz(p1: Vector3, d1: Vector3, p2: Vector3, d2: Vector3) -> Vector3:
	var cross: float = d1.x * d2.z - d1.z * d2.x
	if abs(cross) < 0.0001:
		return (p1 + p2) * 0.5
	var t: float = ((p2.x - p1.x) * d2.z - (p2.z - p1.z) * d2.x) / cross
	return Vector3(p1.x + d1.x * t, p1.y, p1.z + d1.z * t)


# Walk in both +axis and -axis directions to find the corridor edges,
# then return the midpoint between them. axis must be a unit vector.
func _center_on_axis(point: Vector3, axis: Vector3, map_rid: RID) -> Vector3:
	const STEP: float = 0.1
	const MAX_WALK: float = 8.0
	const TOLERANCE: float = 0.05

	var pos_dist: float = _walk_until_off_mesh(point, axis, STEP, MAX_WALK, TOLERANCE, map_rid)
	var neg_dist: float = _walk_until_off_mesh(point, -axis, STEP, MAX_WALK, TOLERANCE, map_rid)
	# Midpoint = point + axis * (pos_dist - neg_dist) / 2
	var shift: float = (pos_dist - neg_dist) * 0.5
	return point + axis * shift


# Walk along (point + axis * d) increasing d until off the nav mesh.
# Returns the last d that was still on-mesh.
# Collapse consecutive corners that are within MERGE_DIST of each other into one,
# averaging their positions. Fixes "stacked spheres" at L-bend corners where two
# nav path points end up at the same physical corner after centering.
func _merge_close_corners(corners: Array[Vector3]) -> Array[Vector3]:
	if corners.size() < 2:
		return corners
	const MERGE_DIST: float = 1.5
	var result: Array[Vector3] = [corners[0]]
	for i: int in range(1, corners.size()):
		var last: Vector3 = result[result.size() - 1]
		var curr: Vector3 = corners[i]
		var flat_last: Vector3 = Vector3(last.x, 0.0, last.z)
		var flat_curr: Vector3 = Vector3(curr.x, 0.0, curr.z)
		if flat_last.distance_to(flat_curr) < MERGE_DIST:
			# Merge: replace last with average.
			result[result.size() - 1] = (last + curr) * 0.5
		else:
			result.append(curr)
	return result


func _walk_until_off_mesh(point: Vector3, axis: Vector3, step: float, max_walk: float, tolerance: float, map_rid: RID) -> float:
	var d: float = 0.0
	var last: float = 0.0
	while d < max_walk:
		d += step
		var test: Vector3 = point + axis * d
		var snap: Vector3 = NavigationServer3D.map_get_closest_point(map_rid, test)
		if snap.distance_to(test) > tolerance:
			break
		last = d
	return last


# Editor-only: clear existing debug, rebuild the path using the world's nav map,
# and spawn fresh debug markers — without entering play mode.
func _editor_rebuild_debug() -> void:
	_clear_debug_markers()

	var region: NavigationRegion3D = get_node_or_null("NavigationRegion3D")
	var player_node: Node3D = get_node_or_null("%Player")
	var finish_node: Node3D = get_node_or_null("%Finish")
	if region == null or player_node == null or finish_node == null:
		push_warning("MovementTest: missing NavigationRegion3D / Player / Finish — cannot build debug.")
		return

	var map_rid: RID = get_world_3d().navigation_map
	# Force the server to sync everything in the editor scene's nav map.
	NavigationServer3D.map_force_update(map_rid)

	var params: NavigationPathQueryParameters3D = NavigationPathQueryParameters3D.new()
	params.map = map_rid
	params.start_position = player_node.global_position
	params.target_position = finish_node.global_position
	var result: NavigationPathQueryResult3D = NavigationPathQueryResult3D.new()
	NavigationServer3D.query_path(params, result)

	if result.path.size() < 2:
		push_warning("MovementTest: editor path query returned no points. Try saving the scene first so the NavigationRegion3D registers with the server.")
		return

	_corners = _simplify_path(result.path)
	_corners = _snap_to_axes(_corners)
	_corners = _collapse_short_segments(_corners)
	_corners = _center_corners_on_corridor(_corners, map_rid)
	_corners = _snap_to_axes(_corners)
	_corners = _merge_close_corners(_corners)
	_pin_path_endpoints(player_node.global_position, finish_node.global_position)
	_corners = _orthogonalize_preserving_endpoints(_corners)
	print("[Editor] Corners (%s): %s" % [_corners.size(), _corners])
	if debug_show_corners:
		_spawn_debug_markers()


func _clear_debug_markers() -> void:
	var existing: Node = get_node_or_null("DebugMarkers")
	if existing != null:
		existing.queue_free()


# Preserve authored start and finish marker positions after navmesh cleanup.
func _pin_path_endpoints(start_position: Vector3, finish_position: Vector3) -> void:
	if _corners.is_empty():
		return
	_corners[0] = start_position
	_corners[_corners.size() - 1] = finish_position


# Insert bends for any remaining diagonal segments without moving endpoints.
func _orthogonalize_preserving_endpoints(corners: Array[Vector3]) -> Array[Vector3]:
	if corners.size() < 2:
		return corners
	const AXIS_TOLERANCE: float = 0.5
	var result: Array[Vector3] = [corners[0]]

	for i: int in range(1, corners.size()):
		var prev: Vector3 = result[result.size() - 1]
		var curr: Vector3 = corners[i]
		var delta: Vector3 = curr - prev
		delta.y = 0.0
		var dx: float = abs(delta.x)
		var dz: float = abs(delta.z)
		if dx <= AXIS_TOLERANCE or dz <= AXIS_TOLERANCE:
			result.append(curr)
			continue

		var bend: Vector3 = _choose_axis_bend(result, curr)
		if prev.distance_to(bend) > AXIS_TOLERANCE:
			result.append(bend)
		result.append(curr)

	return result


# Pick the bend that continues the previous travel axis before turning.
func _choose_axis_bend(result: Array[Vector3], curr: Vector3) -> Vector3:
	var prev: Vector3 = result[result.size() - 1]
	if result.size() >= 2:
		var before: Vector3 = prev - result[result.size() - 2]
		before.y = 0.0
		if abs(before.z) >= abs(before.x):
			return Vector3(prev.x, prev.y, curr.z)
		return Vector3(curr.x, prev.y, prev.z)

	var dx: float = abs(curr.x - prev.x)
	var dz: float = abs(curr.z - prev.z)
	if dz > dx:
		return Vector3(prev.x, prev.y, curr.z)
	return Vector3(curr.x, prev.y, prev.z)


func _on_lane_changed() -> void:
	# When the lane changes, snap player position immediately to the new lane
	# at the same distance along the current segment.
	_apply_position()


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if not _ready_state:
		return
	if _segment_index >= _corners.size() - 1:
		return

	_distance_along += _player.run_speed * delta

	while _segment_index < _corners.size() - 1:
		var seg_length: float = _get_segment_length()
		if _distance_along < seg_length:
			break
		_distance_along -= seg_length
		_segment_index += 1
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
	var lane: int = _player._current_lane
	var seg_start: Vector3 = _get_lane_segment_start(_segment_index, lane)
	var seg_end: Vector3 = _get_lane_segment_end(_segment_index, lane)
	var seg_dir: Vector3 = seg_end - seg_start
	seg_dir.y = 0.0
	if seg_dir.length_squared() < 0.001:
		return
	seg_dir = seg_dir.normalized()
	var distance: float = min(_distance_along, seg_start.distance_to(seg_end))
	var pos: Vector3 = seg_start + seg_dir * distance
	pos.y = _player.global_position.y
	_player.global_position = pos


# Compute the active lane segment length from its lane-specific endpoints.
func _get_segment_length() -> float:
	var lane: int = _player._current_lane
	var seg_start: Vector3 = _get_lane_segment_start(_segment_index, lane)
	var seg_end: Vector3 = _get_lane_segment_end(_segment_index, lane)
	return seg_start.distance_to(seg_end)


# Get the lane-specific start point for a segment.
func _get_lane_segment_start(segment_index: int, lane: int) -> Vector3:
	if segment_index == 0:
		return _get_lane_endpoint(0, 0, 1, lane)
	return _get_lane_turn_point(segment_index, lane)


# Get the lane-specific end point for a segment.
func _get_lane_segment_end(segment_index: int, lane: int) -> Vector3:
	if segment_index >= _corners.size() - 2:
		return _get_lane_endpoint(_corners.size() - 1, _corners.size() - 2, _corners.size() - 1, lane)
	return _get_lane_turn_point(segment_index + 1, lane)


# Offset a path endpoint onto the requested lane.
func _get_lane_endpoint(corner_index: int, segment_start_index: int, segment_end_index: int, lane: int) -> Vector3:
	var corner: Vector3 = _corners[corner_index]
	var direction: Vector3 = _corners[segment_end_index] - _corners[segment_start_index]
	direction.y = 0.0
	if direction.length_squared() < 0.001:
		return corner
	direction = direction.normalized()
	var right: Vector3 = direction.cross(Vector3.UP).normalized()
	return corner + right * LANE_OFFSETS[lane]


# Intersect the incoming and outgoing lane lines at an interior corner.
func _get_lane_turn_point(corner_index: int, lane: int) -> Vector3:
	var prev: Vector3 = _corners[corner_index - 1]
	var corner: Vector3 = _corners[corner_index]
	var next: Vector3 = _corners[corner_index + 1]

	var in_dir: Vector3 = corner - prev
	var out_dir: Vector3 = next - corner
	in_dir.y = 0.0
	out_dir.y = 0.0
	if in_dir.length_squared() < 0.001 or out_dir.length_squared() < 0.001:
		return corner
	in_dir = in_dir.normalized()
	out_dir = out_dir.normalized()

	var lane_offset: float = LANE_OFFSETS[lane]
	var in_right: Vector3 = in_dir.cross(Vector3.UP).normalized()
	var out_right: Vector3 = out_dir.cross(Vector3.UP).normalized()
	var incoming_point: Vector3 = corner + in_right * lane_offset
	var outgoing_point: Vector3 = corner + out_right * lane_offset
	var turn_point: Vector3 = _intersect_lines_xz(incoming_point, in_dir, outgoing_point, out_dir)
	turn_point.y = corner.y
	return turn_point


func _apply_yaw(delta: float) -> void:
	var lane: int = _player._current_lane
	var seg_start: Vector3 = _get_lane_segment_start(_segment_index, lane)
	var seg_end: Vector3 = _get_lane_segment_end(_segment_index, lane)
	var fwd: Vector3 = seg_end - seg_start
	fwd.y = 0.0
	if fwd.length_squared() < 0.001:
		return
	fwd = fwd.normalized()
	var target_yaw: float = atan2(-fwd.x, -fwd.z)
	var turn_weight: float = clamp(10.0 * delta, 0.0, 1.0)
	_player.rotation.y = lerp_angle(_player.rotation.y, target_yaw, turn_weight)
