@tool
class_name MetroMovement
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
const AXIS_TOLERANCE: float = 0.5
const CORNER_ANGLE_THRESHOLD: float = 0.95
const DIAGONAL_TURN_RATIO: float = 0.35
const MIN_SEGMENT_LENGTH: float = 2.0
const MERGE_DISTANCE: float = 1.5
const CENTER_SAMPLE_DISTANCE: float = 2.0
const MIN_CENTER_SAMPLE_DISTANCE: float = 0.25
const CENTER_WALK_STEP: float = 0.1
const CENTER_MAX_WALK: float = 8.0
const CENTER_TOLERANCE: float = 0.05
const TURN_WEIGHT: float = 10.0
const OBSTACLE_STOP_DISTANCE: float = 0.75
const OBSTACLE_RAY_HEIGHT: float = 0.6
## Reverse-rail NPCs are kept this far (in world space) from the player when
## spawning or respawning so they never appear on top of the runner.
const NPC_SAFE_SPAWN_RADIUS: float = 6.0
## Maximum distance to search backward along a reverse rail when enforcing the
## safe spawn radius. Caps the search so it never loops forever.
const NPC_SAFE_SPAWN_MAX_PUSH: float = 40.0
## Distance between staggered NPC spawn slots so they don't pile into a wall.
const NPC_SPAWN_STAGGER_DISTANCE: float = 10.0
## Random jitter added to each stagger slot so spawns don't look gridded.
const NPC_SPAWN_STAGGER_JITTER: float = 10.0
## Lateral spacing between parked NPCs at the finish.
const NPC_PARK_LATERAL_STEP: float = 0.9
## Distance backward (away from the finish marker, into the train) between rows.
const NPC_PARK_DEPTH_STEP: float = 1.1
## Slots per row before wrapping into the next row deeper into the train.
const NPC_PARK_SLOTS_PER_ROW: int = 4

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

@onready var _player: Pawn = %Player
@onready var _finish: Marker3D = %Finish

# Rail direction constants matching Pawn.RailDirection.
const RAIL_FORWARD: int = 0
const RAIL_REVERSE: int = 1

var _ready_state: bool = false
var _corners: Array[Vector3] = []
var _segment_index: int = 0
var _distance_along: float = 0.0
var _start_position: Vector3 = Vector3.ZERO
var _finish_position: Vector3 = Vector3.ZERO

# Each NPC runner is a Dictionary:
# { node: Pawn, direction: int, segment_index: int, distance_along: float, finished: bool }
var _npc_runners: Array[Dictionary] = []
var _parked_npc_count: int = 0


# Start runtime path setup.
func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_player.lane_change_started.connect(_on_lane_change_started)
	_player.shuffle_resolved.connect(_on_shuffle_resolved)
	_wait_for_nav.call_deferred()


# Wait for the navigation map, then cache the processed path.
func _wait_for_nav() -> void:
	print("Wait for nav")
	var params: NavigationPathQueryParameters3D = NavigationPathQueryParameters3D.new()
	var result: NavigationPathQueryResult3D = NavigationPathQueryResult3D.new()
	var map_rid: RID = get_world_3d().navigation_map
	while true:
		await get_tree().physics_frame
		params.map = map_rid
		params.start_position = _player.global_position
		params.target_position = _finish.global_position
		NavigationServer3D.query_path(params, result)
		if result.path.size() >= 2:
			break
	_start_position = _player.global_position
	_finish_position = _finish.global_position
	_corners = _build_corners(result.path, _start_position, _finish_position, map_rid)
	_print_corners("===")
	if debug_show_corners:
		_spawn_debug_markers()
	_register_existing_npcs()
	_ready_state = true


# Find every Pawn in the "npc" group and bind it to the rail.
func _register_existing_npcs() -> void:
	# Track how many NPCs we've registered per direction so each one gets a
	# distinct stagger offset and the group doesn't form a wall.
	var stagger_counts: Dictionary = {RAIL_FORWARD: 0, RAIL_REVERSE: 0}
	for npc: Pawn in get_tree().get_nodes_in_group("npc"):
		var direction: int = npc.get_rail_direction()
		var stagger_index: int = stagger_counts[direction]
		stagger_counts[direction] = stagger_index + 1
		_register_npc(npc, stagger_index)


# Build a runner record for an NPC, snapped to its authored start distance,
# offset by a staggered slot to keep multiple NPCs from spawning on top of
# each other.
func _register_npc(npc: Pawn, stagger_index: int) -> void:
	var direction: int = npc.get_rail_direction()
	var stagger_offset: float = float(stagger_index) * NPC_SPAWN_STAGGER_DISTANCE
	stagger_offset += randf() * NPC_SPAWN_STAGGER_JITTER
	var runner: Dictionary = {
		"node": npc,
		"direction": direction,
		"segment_index": 0,
		"distance_along": maxf(0.0, npc.get_rail_start_distance()) + stagger_offset,
		"finished": false,
	}
	_npc_runners.append(runner)
	_normalize_runner(runner)
	_enforce_safe_spawn_radius(runner)
	_apply_runner_position(runner)
	_apply_runner_yaw_instant(runner)


# Push the runner forward along its rail until its projected world position is
# outside NPC_SAFE_SPAWN_RADIUS of the player. Caps the push distance.
func _enforce_safe_spawn_radius(runner: Dictionary) -> void:
	if NPC_SAFE_SPAWN_RADIUS <= 0.0:
		return
	var pushed: float = 0.0
	var step: float = 0.5
	while pushed < NPC_SAFE_SPAWN_MAX_PUSH:
		var npc: Pawn = runner["node"]
		var lane: int = npc.get_current_lane()
		var distance_along: float = runner["distance_along"]
		var pos: Vector3 = _runner_position_at(runner, lane, distance_along)
		var flat_player: Vector3 = _player.global_position
		flat_player.y = pos.y
		if pos.distance_to(flat_player) >= NPC_SAFE_SPAWN_RADIUS:
			return
		# Advance distance, then re-normalize so it spans into the next segment if needed.
		runner["distance_along"] = distance_along + step
		_normalize_runner(runner)
		var segment_index: int = runner["segment_index"]
		if segment_index >= _corners.size() - 2 and runner["distance_along"] >= _runner_segment_length(runner):
			# Hit the end of the rail without escaping the radius — give up.
			return
		pushed += step


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


# Build a debug line mesh.
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


# Run the nav path through all cleanup passes.
func _build_corners(path: PackedVector3Array, start_position: Vector3, finish_position: Vector3, map_rid: RID) -> Array[Vector3]:
	var corners: Array[Vector3] = _simplify_path(path)
	corners = _snap_to_axes(corners)
	corners = _collapse_short_segments(corners)
	corners = _center_corners_on_corridor(corners, map_rid)
	corners = _snap_to_axes(corners)
	corners = _merge_close_corners(corners)
	corners = _pin_path_endpoints(corners, start_position, finish_position)
	return _orthogonalize_preserving_endpoints(corners)


# Print the processed corner list.
func _print_corners(label: String) -> void:
	print("%s CORNERS (%s) ===" % [label, _corners.size()])
	for i: int in range(_corners.size()):
		print("  [%s] %s" % [i, _corners[i]])


# Snap corner positions so each segment is perfectly axis-aligned (X or Z only).
# When a raw segment changes BOTH X and Z significantly, it's an L-bend the nav
# took diagonally — we insert an intermediate corner to make two axis-aligned
# segments instead.
func _snap_to_axes(corners: Array[Vector3]) -> Array[Vector3]:
	if corners.size() < 2:
		return corners
	var result: Array[Vector3] = []
	result.append(corners[0])

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


# Keep only path points where direction changes.
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
	var result: Array[Vector3] = [corners[0]]
	for i: int in range(1, corners.size() - 1):
		var prev: Vector3 = result[result.size() - 1]
		var curr: Vector3 = corners[i]
		var nxt: Vector3 = corners[i + 1]
		var seg_len: float = (curr - prev).length()
		# Skip this corner if the segment leading into it is too short.
		if seg_len < MIN_SEGMENT_LENGTH:
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
		var in_sample_distance: float = min(CENTER_SAMPLE_DISTANCE, max(MIN_CENTER_SAMPLE_DISTANCE, in_length * 0.5))
		var out_sample_distance: float = min(CENTER_SAMPLE_DISTANCE, max(MIN_CENTER_SAMPLE_DISTANCE, out_length * 0.5))
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
	var pos_dist: float = _walk_until_off_mesh(point, axis, map_rid)
	var neg_dist: float = _walk_until_off_mesh(point, -axis, map_rid)
	# Midpoint = point + axis * (pos_dist - neg_dist) / 2
	var shift: float = (pos_dist - neg_dist) * 0.5
	return point + axis * shift


# Collapse consecutive corners that are close enough to represent the same turn,
# averaging their positions. Fixes "stacked spheres" at L-bend corners where two
# nav path points end up at the same physical corner after centering.
func _merge_close_corners(corners: Array[Vector3]) -> Array[Vector3]:
	if corners.size() < 2:
		return corners
	var result: Array[Vector3] = [corners[0]]
	for i: int in range(1, corners.size()):
		var last: Vector3 = result[result.size() - 1]
		var curr: Vector3 = corners[i]
		var flat_last: Vector3 = Vector3(last.x, 0.0, last.z)
		var flat_curr: Vector3 = Vector3(curr.x, 0.0, curr.z)
		if flat_last.distance_to(flat_curr) < MERGE_DISTANCE:
			# Merge: replace last with average.
			result[result.size() - 1] = (last + curr) * 0.5
		else:
			result.append(curr)
	return result


# Walk along an axis until leaving the nav mesh.
func _walk_until_off_mesh(point: Vector3, axis: Vector3, map_rid: RID) -> float:
	var d: float = 0.0
	var last: float = 0.0
	while d < CENTER_MAX_WALK:
		d += CENTER_WALK_STEP
		var test: Vector3 = point + axis * d
		var snap: Vector3 = NavigationServer3D.map_get_closest_point(map_rid, test)
		if snap.distance_to(test) > CENTER_TOLERANCE:
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

	_corners = _build_corners(result.path, player_node.global_position, finish_node.global_position, map_rid)
	_print_corners("[Editor]")
	if debug_show_corners:
		_spawn_debug_markers()


func _clear_debug_markers() -> void:
	var existing: Node = get_node_or_null("DebugMarkers")
	if existing != null:
		existing.queue_free()


# Preserve authored start and finish marker positions after navmesh cleanup.
func _pin_path_endpoints(corners: Array[Vector3], start_position: Vector3, finish_position: Vector3) -> Array[Vector3]:
	if corners.is_empty():
		return corners
	corners[0] = start_position
	corners[corners.size() - 1] = finish_position
	return corners


# Insert bends for any remaining diagonal segments without moving endpoints.
func _orthogonalize_preserving_endpoints(corners: Array[Vector3]) -> Array[Vector3]:
	if corners.size() < 2:
		return corners
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


func _on_lane_change_started(_from_lane: int, _to_lane: int) -> void:
	# When the lane changes, snap player position immediately to the new lane
	# at the same distance along the current segment.
	_apply_position()


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if not _ready_state:
		return
	_advance_player(delta)
	_advance_npcs(delta)


# Move the player along the rail unless paused or blocked.
func _advance_player(delta: float) -> void:
	if _segment_index >= _corners.size() - 1:
		return
	if _player.is_runner_paused():
		_player.set_movement_blocked(false)
		return
	var blocked: bool = _is_lane_blocked_by_obstacle()
	_player.set_movement_blocked(blocked)
	if blocked:
		return

	_distance_along += _player.run_speed * delta

	while _segment_index < _corners.size() - 1:
		var seg_length: float = _get_advance_segment_length()
		if _distance_along < seg_length:
			break
		_distance_along -= seg_length
		_segment_index += 1
		print("ADVANCE to segment %s" % _segment_index)
		if _segment_index >= _corners.size() - 1:
			print("REACHED DESTINATION at %s" % _player.global_position)
			_player.reach_goal()
			return

	_apply_position()
	_apply_yaw(delta)


# Advance every registered NPC runner along the rail.
func _advance_npcs(delta: float) -> void:
	for runner: Dictionary in _npc_runners:
		_advance_npc_runner(runner, delta)


# Compute the player's current position. When tweening (t > 0) interpolate
# between the floor and ceil lane positions; otherwise single-lane query.
func _apply_position() -> void:
	if _segment_index >= _corners.size() - 1:
		return
	var lane_pos: float = _player.get_lane_position()
	var lane_floor: int = clampi(floori(lane_pos), 0, LANE_OFFSETS.size() - 1)
	var t: float = clampf(lane_pos - float(lane_floor), 0.0, 1.0)
	var pos: Vector3 = _position_for_lane(lane_floor)
	if t > 0.001:
		var lane_ceil: int = clampi(lane_floor + 1, 0, LANE_OFFSETS.size() - 1)
		pos = pos.lerp(_position_for_lane(lane_ceil), t)
	pos.y = _player.global_position.y
	_player.global_position = pos


# Cast a short ray forward along the player's TARGET lane to detect obstacle
# bodies. Using target (not visual / both-lane OR) because mid-tween the body
# isn't physically overlapping the from-lane's obstacles, and a from-lane
# block would keep the player stuck even while they're escaping it.
func _is_lane_blocked_by_obstacle() -> bool:
	var lane: int = _player.get_current_lane()
	var seg_start: Vector3 = _get_lane_segment_start(_segment_index, lane)
	var seg_end: Vector3 = _get_lane_segment_end(_segment_index, lane)
	var seg_dir: Vector3 = seg_end - seg_start
	seg_dir.y = 0.0
	if seg_dir.length_squared() < 0.001:
		return false
	seg_dir = seg_dir.normalized()

	var space_state: PhysicsDirectSpaceState3D = _player.get_world_3d().direct_space_state
	var origin: Vector3 = _player.global_position + Vector3.UP * OBSTACLE_RAY_HEIGHT
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
		origin,
		origin + seg_dir * OBSTACLE_STOP_DISTANCE
	)
	query.exclude = [_player.get_rid()]
	query.collide_with_bodies = true
	var result: Dictionary = space_state.intersect_ray(query)
	if result.is_empty():
		return false
	var collider: Object = result.get("collider")
	return collider != null and collider is Node and (collider as Node).is_in_group("obstacle")


# --- NPC runner helpers --------------------------------------------------

# Drive one NPC runner: pick a lane (with optional avoidance), advance distance,
# handle end-of-rail behavior, and write the world position + yaw.
func _advance_npc_runner(runner: Dictionary, delta: float) -> void:
	var npc: Pawn = runner["node"]
	if not is_instance_valid(npc):
		return
	if npc.is_runner_paused():
		return
	var finished: bool = runner["finished"]
	if finished:
		return

	if npc.should_avoid_obstacles():
		_npc_avoid_obstacle(runner)

	var speed: float = npc.get_rail_speed()
	var prev_distance: float = runner["distance_along"]
	var distance: float = prev_distance + speed * delta
	var segment_index: int = runner["segment_index"]

	while true:
		runner["distance_along"] = distance
		runner["segment_index"] = segment_index
		var seg_length: float = _runner_segment_length(runner)
		if distance < seg_length:
			break
		distance -= seg_length
		segment_index += 1
		if segment_index >= _corners.size() - 1:
			runner["distance_along"] = distance
			runner["segment_index"] = segment_index
			_handle_runner_end_of_rail(runner)
			return
	runner["distance_along"] = distance
	runner["segment_index"] = segment_index

	_apply_runner_position(runner)
	_apply_runner_yaw(runner, delta)


# Reset reverse-rail NPCs to the finish; halt forward NPCs at the train.
func _handle_runner_end_of_rail(runner: Dictionary) -> void:
	var direction: int = runner["direction"]
	if direction == RAIL_REVERSE:
		# REVERSE rail goes Finish->Start; reaching the end means it arrived at Start.
		# Reset to begin again from the finish, with a small random offset so
		# respawning NPCs don't pile up at the same point.
		runner["segment_index"] = 0
		runner["distance_along"] = randf() * NPC_SPAWN_STAGGER_DISTANCE
		_normalize_runner(runner)
		var npc: Pawn = runner["node"]
		npc.set_current_lane(randi() % Pawn.LANE_COUNT)
		_enforce_safe_spawn_radius(runner)
		_apply_runner_position(runner)
		_apply_runner_yaw_instant(runner)
		return

	# FORWARD: reached the finish. Park the NPC at a loiter slot off the rail
	# so it doesn't block the player's lane line into the marker.
	runner["finished"] = true
	runner["segment_index"] = _corners.size() - 2
	runner["distance_along"] = _runner_segment_length(runner)
	var npc_forward: Pawn = runner["node"]
	var slot: int = _parked_npc_count
	_parked_npc_count += 1
	npc_forward.park_at_finish(_compute_park_offset(slot))
	_apply_runner_position(runner)
	_apply_runner_yaw_instant(runner)


# Pack parked NPCs into rows of slots that fan out laterally from the rail's
# last segment, with each row sitting deeper into the train.
func _compute_park_offset(slot: int) -> Vector3:
	if _corners.size() < 2:
		return Vector3.ZERO
	var row: int = slot / NPC_PARK_SLOTS_PER_ROW
	var slot_in_row: int = slot % NPC_PARK_SLOTS_PER_ROW
	# Convert slot_in_row into an alternating offset: +1,-1,+2,-2,+3,-3,+4,...
	# Slot 0 gets a non-zero lateral so the very first parked NPC steps off
	# the player's lane line.
	var alternating: int = (slot_in_row / 2) + 1
	var sign_step: float = 1.0 if (slot_in_row % 2 == 0) else -1.0
	var lateral_units: float = sign_step * float(alternating)

	# Compute the rail's last forward + perpendicular vectors at the finish.
	var last_forward: Vector3 = _corners[_corners.size() - 1] - _corners[_corners.size() - 2]
	last_forward.y = 0.0
	if last_forward.length_squared() < 0.001:
		return Vector3.ZERO
	last_forward = last_forward.normalized()
	var perpendicular: Vector3 = last_forward.cross(Vector3.UP).normalized()

	var lateral: Vector3 = perpendicular * lateral_units * NPC_PARK_LATERAL_STEP
	var depth: Vector3 = -last_forward * float(row + 1) * NPC_PARK_DEPTH_STEP
	return lateral + depth


# Bound a runner's segment_index into the valid range.
func _normalize_runner(runner: Dictionary) -> void:
	if _corners.size() < 2:
		runner["segment_index"] = 0
		runner["distance_along"] = 0.0
		return
	var raw_segment_index: int = runner["segment_index"]
	var segment_index: int = clampi(raw_segment_index, 0, _corners.size() - 2)
	var distance: float = runner["distance_along"]
	runner["segment_index"] = segment_index
	runner["distance_along"] = distance
	while segment_index < _corners.size() - 2:
		var seg_length: float = _runner_segment_length(runner)
		if distance < seg_length:
			runner["segment_index"] = segment_index
			runner["distance_along"] = distance
			return
		distance -= seg_length
		segment_index += 1
		runner["segment_index"] = segment_index
		runner["distance_along"] = distance


# Switch the NPC's lane to a clear one if its current lane is about to hit
# an obstacle within the lookahead distance.
func _npc_avoid_obstacle(runner: Dictionary) -> void:
	var npc: Pawn = runner["node"]
	var lookahead: float = npc.get_obstacle_lookahead()
	if lookahead <= 0.0:
		return
	var current_lane: int = npc.get_current_lane()
	if not _runner_lane_blocked(runner, current_lane, lookahead):
		return
	# Shuffle through the other lanes and pick the first clear one.
	var candidates: Array[int] = []
	for lane: int in range(Pawn.LANE_COUNT):
		if lane != current_lane:
			candidates.append(lane)
	candidates.shuffle()
	for lane: int in candidates:
		if not _runner_lane_blocked(runner, lane, lookahead):
			npc.set_current_lane(lane)
			return


# Sample positions ahead along the runner's rail in a candidate lane and
# return whether any of them sits inside an obstacle.
func _runner_lane_blocked(runner: Dictionary, lane: int, lookahead: float) -> bool:
	var npc: Pawn = runner["node"]
	var space_state: PhysicsDirectSpaceState3D = npc.get_world_3d().direct_space_state
	if space_state == null:
		return false
	var sample_count: int = 4
	var step: float = lookahead / float(sample_count)
	var base_distance: float = runner["distance_along"]
	for i: int in range(1, sample_count + 1):
		var sample_distance: float = base_distance + step * float(i)
		var sample: Vector3 = _runner_position_at(runner, lane, sample_distance)
		var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
			sample + Vector3.UP * (OBSTACLE_RAY_HEIGHT + 0.5),
			sample + Vector3.UP * (OBSTACLE_RAY_HEIGHT - 0.5)
		)
		query.exclude = [npc.get_rid()]
		query.collide_with_bodies = true
		var hit: Dictionary = space_state.intersect_ray(query)
		if hit.is_empty():
			continue
		var collider: Object = hit.get("collider")
		if collider is Node and (collider as Node).is_in_group("obstacle"):
			return true
	return false


# Project a world position for a runner walking a given lane at a given
# distance offset within the current segment (clamps if the offset overruns).
func _runner_position_at(runner: Dictionary, lane: int, distance_along: float) -> Vector3:
	var segment_index: int = runner["segment_index"]
	var direction: int = runner["direction"]
	var seg_start: Vector3 = _runner_lane_segment_start(segment_index, lane, direction)
	var seg_end: Vector3 = _runner_lane_segment_end(segment_index, lane, direction)
	var seg_dir: Vector3 = seg_end - seg_start
	seg_dir.y = 0.0
	if seg_dir.length_squared() < 0.001:
		return seg_start
	var seg_length: float = seg_dir.length()
	seg_dir = seg_dir / seg_length
	var clamped: float = clampf(distance_along, 0.0, seg_length)
	return seg_start + seg_dir * clamped


# Write the runner's world position from its segment + distance + lane.
# Parked NPCs (already at the finish) get a fixed lateral/depth offset so
# they loiter on the train instead of blocking the rail.
func _apply_runner_position(runner: Dictionary) -> void:
	var npc: Pawn = runner["node"]
	var lane: int = npc.get_current_lane()
	var distance_along: float = runner["distance_along"]
	var pos: Vector3 = _runner_position_at(runner, lane, distance_along)
	if npc.is_parked_at_finish():
		var offset: Vector3 = npc.get_parked_offset()
		pos += offset
	pos.y = npc.global_position.y
	npc.global_position = pos


# Smoothly rotate the runner toward its current rail direction.
func _apply_runner_yaw(runner: Dictionary, delta: float) -> void:
	var npc: Pawn = runner["node"]
	var lane: int = npc.get_current_lane()
	var direction: int = runner["direction"]
	var segment_index: int = runner["segment_index"]
	var seg_start: Vector3 = _runner_lane_segment_start(segment_index, lane, direction)
	var seg_end: Vector3 = _runner_lane_segment_end(segment_index, lane, direction)
	var fwd: Vector3 = seg_end - seg_start
	fwd.y = 0.0
	if fwd.length_squared() < 0.001:
		return
	fwd = fwd.normalized()
	var target_yaw: float = atan2(-fwd.x, -fwd.z)
	var turn_weight: float = clamp(TURN_WEIGHT * delta, 0.0, 1.0)
	npc.rotation.y = lerp_angle(npc.rotation.y, target_yaw, turn_weight)


# Snap the runner's yaw to the current rail direction without easing.
func _apply_runner_yaw_instant(runner: Dictionary) -> void:
	var npc: Pawn = runner["node"]
	var lane: int = npc.get_current_lane()
	var direction: int = runner["direction"]
	var segment_index: int = runner["segment_index"]
	var seg_start: Vector3 = _runner_lane_segment_start(segment_index, lane, direction)
	var seg_end: Vector3 = _runner_lane_segment_end(segment_index, lane, direction)
	var fwd: Vector3 = seg_end - seg_start
	fwd.y = 0.0
	if fwd.length_squared() < 0.001:
		return
	fwd = fwd.normalized()
	npc.rotation.y = atan2(-fwd.x, -fwd.z)


# Length of the runner's current segment along its lane.
func _runner_segment_length(runner: Dictionary) -> float:
	var npc: Pawn = runner["node"]
	var lane: int = npc.get_current_lane()
	var direction: int = runner["direction"]
	var segment_index: int = runner["segment_index"]
	var seg_start: Vector3 = _runner_lane_segment_start(segment_index, lane, direction)
	var seg_end: Vector3 = _runner_lane_segment_end(segment_index, lane, direction)
	return seg_start.distance_to(seg_end)


# Lane start point on a directed segment.
# For REVERSE runners we walk corners in reverse order and flip the lane index
# so "lane 0" stays the same world side regardless of travel direction.
func _runner_lane_segment_start(segment_index: int, lane: int, direction: int) -> Vector3:
	if direction == RAIL_REVERSE:
		var reversed_index: int = (_corners.size() - 2) - segment_index
		var flipped_lane: int = (Pawn.LANE_COUNT - 1) - lane
		return _get_lane_segment_end(reversed_index, flipped_lane)
	return _get_lane_segment_start(segment_index, lane)


# Lane end point on a directed segment.
func _runner_lane_segment_end(segment_index: int, lane: int, direction: int) -> Vector3:
	if direction == RAIL_REVERSE:
		var reversed_index: int = (_corners.size() - 2) - segment_index
		var flipped_lane: int = (Pawn.LANE_COUNT - 1) - lane
		return _get_lane_segment_start(reversed_index, flipped_lane)
	return _get_lane_segment_end(segment_index, lane)


# --- end NPC runner helpers ----------------------------------------------


# Compute the active lane segment length from its lane-specific endpoints.
func _get_segment_length() -> float:
	var lane: int = _player.get_current_lane()
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


# World-space position of the player on a given lane at the current
# _distance_along, clamped to that lane's segment length.
func _position_for_lane(lane: int) -> Vector3:
	var seg_start: Vector3 = _get_lane_segment_start(_segment_index, lane)
	var seg_end: Vector3 = _get_lane_segment_end(_segment_index, lane)
	var seg_dir: Vector3 = seg_end - seg_start
	seg_dir.y = 0.0
	if seg_dir.length_squared() < 0.001:
		return seg_start
	var seg_length: float = seg_dir.length()
	seg_dir = seg_dir / seg_length
	var distance: float = min(_distance_along, seg_length)
	return seg_start + seg_dir * distance


# Yaw the player should face on a given lane's segment. Returns the player's
# current yaw on a degenerate segment so lerp_angle doesn't snap to zero.
func _yaw_for_lane(lane: int) -> float:
	var seg_start: Vector3 = _get_lane_segment_start(_segment_index, lane)
	var seg_end: Vector3 = _get_lane_segment_end(_segment_index, lane)
	var fwd: Vector3 = seg_end - seg_start
	fwd.y = 0.0
	if fwd.length_squared() < 0.001:
		return _player.rotation.y
	fwd = fwd.normalized()
	return atan2(-fwd.x, -fwd.z)


# Segment length used by _advance_player to decide when to advance segments.
# During a tween, return the longer of the two lane segments so we don't
# advance before the body has cleared both lanes' geometry — prevents the
# early-snap artifact at corners where the target lane is shorter than the
# source lane.
func _get_advance_segment_length() -> float:
	var lane_pos: float = _player.get_lane_position()
	var lane_floor: int = clampi(floori(lane_pos), 0, LANE_OFFSETS.size() - 1)
	var t: float = clampf(lane_pos - float(lane_floor), 0.0, 1.0)
	var seg_start_floor: Vector3 = _get_lane_segment_start(_segment_index, lane_floor)
	var seg_end_floor: Vector3 = _get_lane_segment_end(_segment_index, lane_floor)
	var len_floor: float = seg_start_floor.distance_to(seg_end_floor)
	if t <= 0.001:
		return len_floor
	var lane_ceil: int = clampi(lane_floor + 1, 0, LANE_OFFSETS.size() - 1)
	var seg_start_ceil: Vector3 = _get_lane_segment_start(_segment_index, lane_ceil)
	var seg_end_ceil: Vector3 = _get_lane_segment_end(_segment_index, lane_ceil)
	return maxf(len_floor, seg_start_ceil.distance_to(seg_end_ceil))


# Rotate the player toward the trajectory of the current lane(s). When tweening
# (t > 0) interpolate yaw between the two lanes' forwards so facing tracks
# position through corners.
func _apply_yaw(delta: float) -> void:
	var lane_pos: float = _player.get_lane_position()
	var lane_floor: int = clampi(floori(lane_pos), 0, LANE_OFFSETS.size() - 1)
	var t: float = clampf(lane_pos - float(lane_floor), 0.0, 1.0)
	var target_yaw: float = _yaw_for_lane(lane_floor)
	if t > 0.001:
		var lane_ceil: int = clampi(lane_floor + 1, 0, LANE_OFFSETS.size() - 1)
		target_yaw = lerp_angle(target_yaw, _yaw_for_lane(lane_ceil), t)
	var turn_weight: float = clamp(TURN_WEIGHT * delta, 0.0, 1.0)
	_player.rotation.y = lerp_angle(_player.rotation.y, target_yaw, turn_weight)


# Move the runner back after a failed subway shuffle collision.
func _on_shuffle_resolved(succeeded: bool, _direction: int) -> void:
	if succeeded:
		return
	_rewind_distance(_player.shuffle_knockback_distance)
	_apply_position()


# Rewind along the current lane path by the requested distance.
func _rewind_distance(distance: float) -> void:
	var remaining: float = max(distance, 0.0)
	while remaining > 0.0 and _segment_index >= 0:
		if _distance_along >= remaining:
			_distance_along -= remaining
			return
		remaining -= _distance_along
		if _segment_index <= 0:
			_distance_along = 0.0
			return
		_segment_index -= 1
		_distance_along = _get_segment_length()
