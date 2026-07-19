@tool
class_name MetroMovement
extends Node3D

# Drives all actors (player + NPCs) parametrically along nav path segments.
#
# Each segment has: start point, end point, forward direction, length.
# Actor position = segment.start + forward * distance + right * lane_offset
# Distance increments at run_speed each frame.
# When distance >= segment length, advance to next segment.
#
# Lane is a fixed perpendicular offset to the CURRENT segment's direction:
#   Lane 0 (left)   = -1.0 perpendicular
#   Lane 1 (center) =  0.0
#   Lane 2 (right)  = +1.0 perpendicular
#
# At interior corners non-center lanes snap from "perpendicular to old segment"
# to "perpendicular to new segment" — a ~sqrt(2)*offset world-space jump for
# 90° turns. This keeps strafes purely perpendicular to the current rail
# direction (the previous lane-line-intersection geometry baked a parallel-to-
# rail component into non-center lanes, so post-turn strafes drifted forward
# or backward along the rail).

const LANE_OFFSETS: Array[float] = [-1.0, 0.0, 1.0]
const AXIS_TOLERANCE: float = 0.5
const CORNER_ANGLE_THRESHOLD: float = 0.95
const DIAGONAL_TURN_RATIO: float = 0.35
const MIN_SEGMENT_LENGTH: float = 2.0
const MERGE_DISTANCE: float = 1.5
const CENTER_WALK_STEP: float = 0.1
const CENTER_MAX_WALK: float = 8.0
const CENTER_TOLERANCE: float = 0.05
const ROUTE_SAMPLE_STEP: float = 0.5
const ROUTE_NAV_TOLERANCE: float = 0.1
const TURN_WEIGHT: float = 10.0
const OBSTACLE_STOP_DISTANCE: float = 0.75
const OBSTACLE_RAY_HEIGHT: float = 0.6
## Max distance spread when a reverse NPC respawns so they don't pile up.
const NPC_RESPAWN_STAGGER: float = 10.0
## Extra rail-meters past `encounter_lookahead` before clearing a runner's
## shuffle_ignored field. Small dead-band prevents flapping when the runner
## and the ignored pawn travel at near-identical speeds.
const ENCOUNTER_IGNORE_HYSTERESIS: float = 0.5
## Buffer (rail-meters) left between a knocked-back runner and the nearest
## same-lane peer behind them, so the rewind doesn't land coincident with the
## rear pawn (mutual speed-modulation would otherwise lock both at zero).
const KNOCKBACK_REAR_BUFFER: float = 0.1


class RailProjection:
	var segment_index: int = 0
	var distance_along: float = 0.0


# Per-frame snapshot used by the encounter scan. Built once at the start of
# _scan_encounters_for_all_runners so every pair-check reads the same positions
# regardless of runner array order.
class EncounterSnap:
	var runner: Runner
	var centerline: float = 0.0
	# Occupied lane (world-side-consistent) — see _runner_occupied_lane.
	# Rounded `_lane_position` (current body overlap), NOT the target lane,
	# so a tweening pawn isn't pre-claimed at the destination.
	var lane: int = 0
	var lookahead: float = 0.0  # 0 = does not initiate scans (paused / no brain)


# Per-pair near-miss state. Phase is monotonic; crossover emits
# `runner_passed` only when QUALIFIED && had_input.
class PassState:
	enum Phase { TRACKED, QUALIFIED, TRIGGERED }
	var phase: Phase = Phase.TRACKED
	# Sticky-true once the scanning runner started a lane change while tracked.
	var had_input: bool = false


class Runner:
	var node: Pawn
	var segment_index: int = 0
	var distance_along: float = 0.0
	var toward_finish: bool = true
	var finished: bool = false
	# Pawn the encounter scan should skip until it drifts past
	# (encounter_lookahead + IGNORE_HYSTERESIS) rail-meters ahead. Set by
	# PlayerBrain on same-direction instant-knockdown so the scan doesn't
	# re-trigger the same encounter on recovery. Cleared by the scan itself.
	var shuffle_ignored: Pawn
	# Opposing pawns currently within ±pass_radius ahead. Empty if opted out.
	var tracked_passes: Dictionary[Pawn, PassState] = {}

	func _init(p_node: Pawn, p_segment_index: int, p_distance_along: float, p_toward_finish: bool) -> void:
		node = p_node
		segment_index = p_segment_index
		distance_along = p_distance_along
		toward_finish = p_toward_finish


@export_group("Subway Shuffle")
## Wall-clock time (s) the initiating brain has to commit a side. Single
## source of truth — every Pawn reads this via its `_metro_movement` back-ref.
## Pawn falls back to a const default if the back-ref is null (pre-registration
## / unit-test scenarios), but the encounter scan can only fire post-registration
## so production paths always read this value. Default preserves the prior
## per-pawn `Pawn.tscn` override (= 2.5 s wall-clock during bullet-time).
@export_range(0.05, 5.0, 0.01, "suffix:s") var shuffle_choice_time: float = 2.5
## Multiplier applied to `Engine.time_scale` during a shuffle. Read by
## PlayerBrain.on_shuffle_entered to mutate time_scale; AIBrain ignores it.
## Default 0.2 = 5× slow-mo. AI-vs-AI shuffles run at full game-time.
@export_range(0.05, 1.0, 0.01) var shuffle_bullet_time_scale: float = 0.2

@export_group("NPC Spawning")
## NPC packed scenes to randomly spawn at startup.
@export var npc_scenes: Array[PackedScene] = []
## Spawn weight for each entry in npc_scenes (1.0 = 100%, 0.1 = 10%).
## Matched by index; missing entries default to 1.0.
@export var npc_weights: Array[float] = []
## How many NPCs to place along the rail when the level starts.
@export var starting_npc_count: int = 0
## Minimum rail-meter distance from the player a startup NPC may spawn.
@export var safe_spawn_range: float = 5.0

@export_group("Debug")
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

@onready var _finish: Marker3D = %Finish


var _ready_state: bool = false
var _corners: Array[Vector3] = []
var _start_position: Vector3 = Vector3.ZERO
var _finish_position: Vector3 = Vector3.ZERO

var _runners: Array[Runner] = []
# Resolved during _wait_for_nav by querying the "player" group, which
# PlayerBrain populates at bind time. Used only to anchor the rail and seed
# the first runner — every other Pawn (player or NPC) flows through the same
# registration path.
var _player: Pawn


# Start runtime path setup.
func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_wait_for_nav.call_deferred()


# Level-root meta-input. Reset blows the scene away and reloads it; restoring
# `Engine.time_scale` first matters because it's the only piece of state that
# survives `reload_current_scene()` (a leftover of any active subway-shuffle
# bullet-time would otherwise carry into the new run).
func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if event.is_action_pressed("reset"):
		Engine.time_scale = 1.0
		get_tree().reload_current_scene()


# Wait for the navigation map, then cache the processed path.
func _wait_for_nav() -> void:
	_player = get_tree().get_first_node_in_group("player") as Pawn
	if _player == null:
		push_error("MetroMovement: no Pawn in group \"player\" — PlayerBrain.add_to_group must run before _wait_for_nav.")
		return
	var params: NavigationPathQueryParameters3D = NavigationPathQueryParameters3D.new()
	var result: NavigationPathQueryResult3D = NavigationPathQueryResult3D.new()
	var map_rid: RID = get_world_3d().navigation_map
	while true:
		await get_tree().physics_frame
		params.map = map_rid
		params.path_postprocessing = NavigationPathQueryParameters3D.PATH_POSTPROCESSING_EDGECENTERED
		params.start_position = _player.global_position
		params.target_position = _finish.global_position
		NavigationServer3D.query_path(params, result)
		if result.path.size() >= 2:
			break
	_start_position = _player.global_position
	_finish_position = _finish.global_position
	_corners = _build_corners(result.path, _start_position, _finish_position, map_rid)
	if debug_show_corners:
		_print_corners("===")
		_spawn_debug_markers()
	# Player first (rail anchor), then NPCs by group. Single registration path
	# for both — see `_register_pawn` below.
	register_pawn(_player)
	for npc: Pawn in get_tree().get_nodes_in_group("npc"):
		register_pawn(npc)
	_spawn_starting_npcs()
	_ready_state = true


# Public: register a Pawn as a runner on the rail with auto-detected direction.
# Idempotent — no-op if the Pawn is already registered (so dynamic spawn callers
# don't have to check). Player Pawns (group "player") are seeded at the rail
# origin (0, 0) toward_finish=true; the player's authored world position has
# anchored `_corners[0]` in `_wait_for_nav`, so projecting them adds floating-
# point noise without buying anything. NPCs are projected from their authored
# world position and use `_npc_toward_finish` to derive direction.
func register_pawn(pawn: Pawn) -> void:
	if pawn == null:
		return
	var toward_finish: bool = true if pawn.is_in_group("player") else _npc_toward_finish(pawn)
	_register_pawn(pawn, toward_finish)


# Public: register a Pawn at an explicit direction. Used by `_spawn_starting_npcs`
# to randomize NPC direction on spawn. Idempotent. Player paths shouldn't call
# this — `register_pawn(player)` always seeds toward_finish=true.
func register_pawn_with_direction(pawn: Pawn, toward_finish: bool) -> void:
	if pawn == null:
		return
	_register_pawn(pawn, toward_finish)


# Single registration body. Typed bool — no Variant. Player vs NPC differ only
# in seeding (origin vs projection) and whether de-stagger runs.
func _register_pawn(pawn: Pawn, toward_finish: bool) -> void:
	if _find_runner_for(pawn) != null:
		return
	var is_player: bool = pawn.is_in_group("player")
	var seg: int = 0
	var dist: float = 0.0
	if not is_player:
		var proj: RailProjection = _project_onto_rail(pawn.global_position, toward_finish)
		seg = proj.segment_index
		dist = proj.distance_along
	pawn.set_rail_forward(toward_finish)
	var runner: Runner = Runner.new(pawn, seg, dist, toward_finish)
	_runners.append(runner)
	pawn._metro_movement = self
	_wire_runner_signals(runner)
	if not is_player:
		var min_gap: float = pawn.brain.get_min_peer_gap() if pawn.brain != null else 1.0
		_destagger_runner_spawn(runner, min_gap)
	_apply_runner_position(runner)
	_apply_runner_yaw_instant(runner)


# Instantiate starting_npc_count NPCs from npc_scenes using weighted random
# selection, placing each at a random rail position with a random travel direction.
# Positions within safe_spawn_range rail-meters of the player are rejected and
# re-rolled (up to 20 attempts per NPC before accepting the last candidate).
func _spawn_starting_npcs() -> void:
	if npc_scenes.is_empty() or starting_npc_count <= 0 or _corners.size() < 2:
		return
	var total_rail_length: float = 0.0
	for i: int in range(_corners.size() - 1):
		total_rail_length += _corners[i].distance_to(_corners[i + 1])
	var player_runner: Runner = _find_runner_for(_player)
	var player_centerline: float = player_runner.distance_along if player_runner != null else 0.0
	# Forward-direction (toward-finish) NPCs are capped by the train's slot
	# count — late arrivals can't board, and we don't fan-out on the platform
	# any more. Any spawn that rolls forward past the cap is forced reverse so
	# total spawn count stays at `starting_npc_count`. Player isn't counted
	# here: race-for-a-seat semantics let greeters legitimately fill every
	# slot before the player arrives.
	var train: Train = get_tree().get_first_node_in_group("train") as Train
	var forward_cap: int = train.get_slot_count() if train != null else starting_npc_count
	if train != null and starting_npc_count > forward_cap * 2:
		push_warning("MetroMovement: starting_npc_count (%d) more than 2x train slot_count (%d); reverse-direction spawns will dominate." % [starting_npc_count, forward_cap])
	var forward_count: int = 0
	for _i: int in range(starting_npc_count):
		var scene: PackedScene = _pick_weighted_npc_scene()
		if scene == null:
			continue
		var npc: Node = scene.instantiate()
		if not (npc is Pawn):
			npc.queue_free()
			continue
		var nav_region: Node = get_node_or_null("NavigationRegion3D")
		var spawn_parent: Node = nav_region if nav_region != null else self
		spawn_parent.add_child(npc, true)
		var pawn: Pawn = npc as Pawn
		var toward_finish: bool = randi() % 2 == 0
		if toward_finish and forward_count >= forward_cap:
			toward_finish = false
		if toward_finish:
			forward_count += 1
		var chosen_dist: float = randf() * total_rail_length
		var max_attempts: int = 20
		for attempt: int in range(max_attempts):
			var candidate: float = randf() * total_rail_length
			if absf(candidate - player_centerline) >= safe_spawn_range:
				chosen_dist = candidate
				break
			if attempt == max_attempts - 1:
				chosen_dist = candidate
		var seg: int = 0
		var dist_remaining: float = chosen_dist
		while seg < _corners.size() - 2:
			var seg_len: float = _corners[seg].distance_to(_corners[seg + 1])
			if dist_remaining <= seg_len:
				break
			dist_remaining -= seg_len
			seg += 1
		var seg_start: Vector3 = _corners[seg]
		var seg_end: Vector3 = _corners[seg + 1]
		var seg_dir: Vector3 = (seg_end - seg_start).normalized()
		pawn.global_position = seg_start + seg_dir * dist_remaining
		pawn.set_current_lane(randi() % Pawn.LANE_COUNT)
		register_pawn_with_direction(pawn, toward_finish)
		if pawn.visual != null:
			pawn.visual.randomize_animation_offset()


# Pick a random scene from npc_scenes using per-entry weights.
func _pick_weighted_npc_scene() -> PackedScene:
	var total_weight: float = 0.0
	for i: int in range(npc_scenes.size()):
		var w: float = npc_weights[i] if i < npc_weights.size() else 1.0
		total_weight += maxf(w, 0.0)
	if total_weight <= 0.0:
		return null
	var roll: float = randf() * total_weight
	var accumulated: float = 0.0
	for i: int in range(npc_scenes.size()):
		var w: float = npc_weights[i] if i < npc_weights.size() else 1.0
		accumulated += maxf(w, 0.0)
		if roll <= accumulated:
			return npc_scenes[i]
	return npc_scenes[npc_scenes.size() - 1]


# Walk a freshly-spawned runner backward along its rail direction in
# min_gap-sized steps until no other runner sits within `min_gap` rail-meters
# in the same target lane. Bounded iteration so a fully-packed start lane
# can't loop forever — clamps at segment 0, distance 0 and accepts the
# remaining overlap. Distance comparison is signed centerline-based so it
# works for both FORWARD and REVERSE runners.
func _destagger_runner_spawn(runner: Runner, min_gap: float) -> void:
	var max_iter: int = _runners.size() + 5
	while max_iter > 0:
		max_iter -= 1
		if _spawn_overlap_pawn(runner, min_gap) == null:
			return
		if runner.distance_along >= min_gap:
			runner.distance_along -= min_gap
			continue
		if runner.segment_index > 0:
			var leftover: float = min_gap - runner.distance_along
			runner.segment_index -= 1
			runner.distance_along = maxf(
				0.0,
				_runner_segment_length(runner) - leftover
			)
			continue
		runner.distance_along = 0.0
		return


# Find another runner in the same target lane whose centerline distance is
# within `min_gap` of the spawning runner. Null = clear.
func _spawn_overlap_pawn(runner: Runner, min_gap: float) -> Pawn:
	var target_lane: int = _runner_target_lane(runner)
	var center: float = _runner_centerline_position(runner)
	for other: Runner in _runners:
		if other == runner or not is_instance_valid(other.node):
			continue
		if _runner_target_lane(other) != target_lane:
			continue
		if absf(_runner_centerline_position(other) - center) < min_gap:
			return other.node
	return null


# Connect Pawn → MetroMovement signals for any runner. The runner is bound
# into the callable so the handler doesn't have to look it up.
func _wire_runner_signals(runner: Runner) -> void:
	runner.node.lane_change_started.connect(_on_runner_lane_change_started.bind(runner))
	runner.node.knocked_down.connect(_on_runner_knocked_down.bind(runner))
	runner.node.shuffle_began.connect(_on_runner_shuffle_began.bind(runner))


# Public accessors for the shuffle timing exports. Pawn calls these via its
# `_metro_movement` back-ref, with const fallbacks for pre-registration.
# Wrapping the @export reads behind methods means the API surface stays
# explicit even though the underlying field is also accessible.
func get_shuffle_choice_time() -> float:
	return shuffle_choice_time


func get_shuffle_bullet_time_scale() -> float:
	return shuffle_bullet_time_scale


# Public: mark `other` as ignored by `pawn`'s encounter scan. Routed through
# Pawn.set_shuffle_ignored so brains don't need a MetroMovement reference.
# Cleared by the encounter scan when `other` drifts past the hysteresis margin.
func set_runner_shuffle_ignored(pawn: Pawn, other: Pawn) -> void:
	var runner: Runner = _find_runner_for(pawn)
	if runner == null:
		return
	runner.shuffle_ignored = other


# Internal lookup: find the Runner wrapping a given Pawn, or null.
func _find_runner_for(pawn: Pawn) -> Runner:
	for runner: Runner in _runners:
		if runner.node == pawn:
			return runner
	return null


# Find the rail segment closest to world_pos and return runner coordinates
# in the actor's directional system.
# toward_finish=true  → forward coordinates (segment 0 = corners[0]→corners[1])
# toward_finish=false → reversed coordinates (segment 0 = corners[last]→corners[last-1])
func _project_onto_rail(world_pos: Vector3, toward_finish: bool) -> RailProjection:
	var best_segment: int = 0
	var best_distance: float = 0.0
	var best_dist_sq: float = INF
	for i: int in range(_corners.size() - 1):
		var seg_start: Vector3 = Vector3(_corners[i].x, 0.0, _corners[i].z)
		var seg_end: Vector3 = Vector3(_corners[i + 1].x, 0.0, _corners[i + 1].z)
		var seg: Vector3 = seg_end - seg_start
		var seg_len: float = seg.length()
		if seg_len < 0.001:
			continue
		var seg_dir: Vector3 = seg / seg_len
		var flat_pos: Vector3 = Vector3(world_pos.x, 0.0, world_pos.z)
		var projected: float = clampf((flat_pos - seg_start).dot(seg_dir), 0.0, seg_len)
		var closest: Vector3 = seg_start + seg_dir * projected
		var dist_sq: float = flat_pos.distance_squared_to(closest)
		if dist_sq < best_dist_sq:
			best_dist_sq = dist_sq
			best_segment = i
			best_distance = projected
	var result: RailProjection = RailProjection.new()
	if not toward_finish:
		var fwd_seg_len: float = _corners[best_segment].distance_to(_corners[best_segment + 1])
		result.segment_index = (_corners.size() - 2) - best_segment
		result.distance_along = maxf(0.0, fwd_seg_len - best_distance)
	else:
		result.segment_index = best_segment
		result.distance_along = best_distance
	return result


# Determine NPC travel direction by checking whether its destination node sits
# closer to the finish end or the start end of the rail.
func _npc_toward_finish(npc: Pawn) -> bool:
	if npc.brain == null or _corners.size() < 2:
		return true
	var dest: Node3D = npc.brain.get_destination()
	if dest == null:
		return true
	var dest_xz: Vector3 = Vector3(dest.global_position.x, 0.0, dest.global_position.z)
	var start_xz: Vector3 = Vector3(_corners[0].x, 0.0, _corners[0].z)
	var finish_corner: Vector3 = _corners[_corners.size() - 1]
	var finish_xz: Vector3 = Vector3(finish_corner.x, 0.0, finish_corner.z)
	return dest_xz.distance_squared_to(finish_xz) <= dest_xz.distance_squared_to(start_xz)


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
	corners = _snap_to_axes(corners, map_rid)
	corners = _collapse_short_segments(corners)
	corners = _center_segments_on_corridor(corners, map_rid)
	corners = _snap_to_axes(corners, map_rid)
	corners = _merge_close_corners(corners)
	corners = _pin_path_endpoints(corners, start_position, finish_position)
	return _orthogonalize_preserving_endpoints(corners, map_rid)


# Print the processed corner list.
func _print_corners(label: String) -> void:
	print("%s CORNERS (%s) ===" % [label, _corners.size()])
	for i: int in range(_corners.size()):
		print("  [%s] %s" % [i, _corners[i]])


# Snap corner positions so each segment is perfectly axis-aligned (X or Z only).
# When a raw segment changes BOTH X and Z significantly, it's an L-bend the nav
# took diagonally — we insert an intermediate corner to make two axis-aligned
# segments instead.
func _snap_to_axes(corners: Array[Vector3], map_rid: RID) -> Array[Vector3]:
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
			var bend: Vector3 = _choose_axis_bend(result, curr, map_rid)
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


# Recenter each rail segment from its midpoint, then intersect segment
# centerlines to place turns in the middle lane.
func _center_segments_on_corridor(corners: Array[Vector3], map_rid: RID) -> Array[Vector3]:
	if corners.size() < 3:
		return corners
	var line_points: Array[Vector3] = []
	var line_dirs: Array[Vector3] = []
	for i: int in range(corners.size() - 1):
		var seg_start: Vector3 = corners[i]
		var seg_end: Vector3 = corners[i + 1]
		var seg_dir: Vector3 = seg_end - seg_start
		seg_dir.y = 0.0
		if seg_dir.length_squared() < 0.001:
			line_points.append(seg_start)
			line_dirs.append(Vector3.RIGHT)
			continue
		seg_dir = seg_dir.normalized()
		var seg_perp: Vector3 = seg_dir.cross(Vector3.UP).normalized()
		var segment_midpoint: Vector3 = (seg_start + seg_end) * 0.5
		line_points.append(_center_on_axis(segment_midpoint, seg_perp, map_rid))
		line_dirs.append(seg_dir)

	var result: Array[Vector3] = [corners[0]]
	for i: int in range(1, corners.size() - 1):
		var centered: Vector3 = _intersect_lines_xz(
			line_points[i - 1],
			line_dirs[i - 1],
			line_points[i],
			line_dirs[i]
		)
		centered.y = corners[i].y
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
	params.path_postprocessing = NavigationPathQueryParameters3D.PATH_POSTPROCESSING_EDGECENTERED
	params.start_position = player_node.global_position
	params.target_position = finish_node.global_position
	var result: NavigationPathQueryResult3D = NavigationPathQueryResult3D.new()
	NavigationServer3D.query_path(params, result)

	if result.path.size() < 2:
		push_warning("MovementTest: editor path query returned no points. Try saving the scene first so the NavigationRegion3D registers with the server.")
		return

	_corners = _build_corners(result.path, player_node.global_position, finish_node.global_position, map_rid)
	if debug_show_corners:
		_print_corners("[Editor]")
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
func _orthogonalize_preserving_endpoints(corners: Array[Vector3], map_rid: RID) -> Array[Vector3]:
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

		var bend: Vector3 = _choose_axis_bend(result, curr, map_rid)
		if prev.distance_to(bend) > AXIS_TOLERANCE:
			result.append(bend)
		result.append(curr)

	return result


# Pick the bend that best stays on the navigation mesh.
func _choose_axis_bend(result: Array[Vector3], curr: Vector3, map_rid: RID) -> Vector3:
	var prev: Vector3 = result[result.size() - 1]
	var z_first: Vector3 = Vector3(prev.x, prev.y, curr.z)
	var x_first: Vector3 = Vector3(curr.x, prev.y, prev.z)
	var z_first_score: float = _score_axis_route_on_navmesh(prev, z_first, curr, map_rid)
	var x_first_score: float = _score_axis_route_on_navmesh(prev, x_first, curr, map_rid)
	if absf(z_first_score - x_first_score) > 0.01:
		return z_first if z_first_score > x_first_score else x_first

	if result.size() >= 2:
		var before: Vector3 = prev - result[result.size() - 2]
		before.y = 0.0
		if abs(before.z) >= abs(before.x):
			return z_first
		return x_first

	var dx: float = abs(curr.x - prev.x)
	var dz: float = abs(curr.z - prev.z)
	if dz > dx:
		return z_first
	return x_first


# Score an L-shaped route by how closely its samples remain on the navmesh.
func _score_axis_route_on_navmesh(from: Vector3, bend: Vector3, to: Vector3, map_rid: RID) -> float:
	return _score_navmesh_segment(from, bend, map_rid) + _score_navmesh_segment(bend, to, map_rid)


# Score one axis-aligned segment against the navigation map.
func _score_navmesh_segment(from: Vector3, to: Vector3, map_rid: RID) -> float:
	var length: float = from.distance_to(to)
	if length <= 0.001:
		return 0.0
	var sample_count: int = maxi(1, ceili(length / ROUTE_SAMPLE_STEP))
	var score: float = 0.0
	for i: int in range(sample_count + 1):
		var weight: float = float(i) / float(sample_count)
		var sample: Vector3 = from.lerp(to, weight)
		var closest: Vector3 = NavigationServer3D.map_get_closest_point(map_rid, sample)
		var distance: float = closest.distance_to(sample)
		if distance <= ROUTE_NAV_TOLERANCE:
			score += 1.0
		else:
			score -= minf(distance, 1.0)
	return score


func _on_runner_lane_change_started(_from_lane: int, _to_lane: int, runner: Runner) -> void:
	_apply_runner_position(runner)
	# Credit every in-flight encounter with the input action.
	for state: PassState in runner.tracked_passes.values():
		state.had_input = true


# Mark the pair TRIGGERED so the post-shuffle crossover silent-drops.
func _on_runner_shuffle_began(other: Pawn, _other_telegraph: int, _deadline_msec: int, runner: Runner) -> void:
	if runner.node.get_pass_radius() <= 0.0:
		return
	if runner.tracked_passes.has(other):
		runner.tracked_passes[other].phase = PassState.Phase.TRIGGERED
	else:
		# Seed TRIGGERED for pairs that engaged without prior tracking.
		var state: PassState = PassState.new()
		state.phase = PassState.Phase.TRIGGERED
		runner.tracked_passes[other] = state


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if not _ready_state:
		return
	for runner: Runner in _runners:
		_advance_runner(runner, delta)
	_scan_encounters_for_all_runners()


# Advance one runner along the rail. Single code path for player + NPCs;
# obstacle response is decided by the runner's Brain via obstacle_detected.
func _advance_runner(runner: Runner, delta: float) -> void:
	if not is_instance_valid(runner.node):
		return
	if runner.finished:
		return
	if runner.node.is_advancing_paused():
		runner.node.set_movement_blocked(false)
		return

	# SHUFFLING falls through here. is_advancing_paused() excludes SHUFFLING
	# by design (see Pawn.is_advancing_paused docstring) — the pawn closes
	# the gap at the slow-approach speed (computed live from shuffle.entry_gap
	# in Pawn.get_rail_speed) during the choice window. Obstacle scanning is
	# suppressed for SHUFFLING in Pawn.should_avoid_obstacles, so the block
	# below is effectively a no-op for SHUFFLING.

	# MetroMovement detects, Brain decides. The signal handler runs
	# synchronously, so by the next line the pawn may be knocked down or
	# may have switched lanes.
	if runner.node.should_avoid_obstacles():
		_detect_obstacle_and_notify_brain(runner)
		if runner.node.is_advancing_paused():
			return

	runner.node.set_movement_blocked(false)

	var speed: float = runner.node.get_rail_speed()
	var distance: float = runner.distance_along + speed * delta
	var segment_index: int = runner.segment_index

	while true:
		runner.distance_along = distance
		runner.segment_index = segment_index
		var seg_length: float = _runner_segment_length(runner)
		if distance < seg_length:
			break
		distance -= seg_length
		segment_index += 1
		if segment_index >= _corners.size() - 1:
			runner.distance_along = distance
			runner.segment_index = segment_index
			_handle_end_of_rail(runner)
			return
	runner.distance_along = distance
	runner.segment_index = segment_index

	_apply_runner_position(runner)
	_apply_runner_yaw(runner, delta)


# Convert a runner's direction-relative lane index to a world-side-consistent
# physical lane. FORWARD runners use the index as-is; REVERSE runners get the
# index flipped to match the FORWARD frame (mirrors the flip in
# _runner_lane_segment_start). Lane-occupancy queries (clearance, spawn, queue
# avoidance) compare THIS so a FORWARD lane 2 and a REVERSE lane 2 don't
# falsely match — they're on opposite physical sides of the rail. Reads the
# pawn's TARGET lane (`get_current_lane`) — a tweening pawn is treated as
# already owning the destination for routing/queue purposes. The encounter
# scan uses `_runner_occupied_lane` instead so a swerver isn't pre-claimed
# at the destination — a same-lane shuffle requires both bodies to actually
# overlap, not just intend to.
func _runner_target_lane(runner: Runner) -> int:
	if runner.toward_finish:
		return runner.node.get_current_lane()
	return (Pawn.LANE_COUNT - 1) - runner.node.get_current_lane()


# Encounter-scan-only occupied lane: rounds `_lane_position` (the tweened
# scalar) to the nearest integer, then mirrors the FORWARD/REVERSE flip from
# `_runner_target_lane` (so the result is in the same world-side-consistent
# coordinate frame). A pawn mid-tween is read as being in the lane its
# body currently overlaps — once they've crossed half the lane width they
# count as "in" the destination, before that they still count as "in" the
# source. Combined with the mid-tween engagement gate in `Pawn.start_shuffle`,
# this means a swerver and an opposing pawn can pass through the same target
# lane without locking into a shuffle as long as the swerver is still moving.
#
# Diverges from `_runner_target_lane` BY DESIGN. The encounter scan asks
# "are bodies physically overlapping right now?" — collision-prediction
# semantics, OCCUPIED lane. The lane-change gate (via `find_lane_occupant_ahead`
# / `get_lane_clearance` / `Pawn.can_enter_lane`) asks "does anyone hold a
# reservation on this lane?" — TARGET lane. If the encounter scan used TARGET,
# rapid-tap input could flip the body's target lane and "escape" an opposing
# pawn's encounter window without the body actually moving. Keep the split.
func _runner_occupied_lane(runner: Runner) -> int:
	var raw: int = runner.node.get_occupied_lane()
	if runner.toward_finish:
		return raw
	return (Pawn.LANE_COUNT - 1) - raw


# Length of the runner's current segment. Lane-independent now that lane
# offsets are perpendicular-only — every lane in a segment has the same
# centerline length. Uses lane 0 internally as an arbitrary anchor; the
# perpendicular offset cancels in seg_end - seg_start.
func _runner_segment_length(runner: Runner) -> float:
	var seg_start: Vector3 = _runner_lane_segment_start(runner.segment_index, 0, runner.toward_finish)
	var seg_end: Vector3 = _runner_lane_segment_end(runner.segment_index, 0, runner.toward_finish)
	return seg_start.distance_to(seg_end)


# Signed centerline distance from corners[0] along the rail. Direction-agnostic
# scalar — FORWARD runners increase, REVERSE runners decrease. Encounter scan
# uses the difference between two runners' centerline positions to decide who
# is ahead of whom on the rail. Centerline (not per-lane) is used because the
# scan only needs ~corner-fuzziness accuracy to gate same-lane encounters.
func _runner_centerline_position(runner: Runner) -> float:
	if _corners.size() < 2:
		return 0.0
	var pos: float = 0.0
	if runner.toward_finish:
		for i: int in range(runner.segment_index):
			pos += _corners[i].distance_to(_corners[i + 1])
		pos += runner.distance_along
		return pos
	# Reverse runner: segment_index counts from the finish end. Total rail length
	# minus distance walked from the finish gives the equivalent forward scalar.
	var total: float = 0.0
	for i: int in range(_corners.size() - 1):
		total += _corners[i].distance_to(_corners[i + 1])
	var reverse_walked: float = 0.0
	var last_idx: int = _corners.size() - 1
	for i: int in range(runner.segment_index):
		reverse_walked += _corners[last_idx - i].distance_to(_corners[last_idx - i - 1])
	reverse_walked += runner.distance_along
	return total - reverse_walked


# Handle a runner reaching the end of its rail. Brain decides what kind of
# end this is — finish line, parking spot, or loop-back — and MetroMovement
# performs the rail-state bookkeeping to make it happen.
func _handle_end_of_rail(runner: Runner) -> void:
	var action: int = Brain.EndOfRailAction.RESPAWN
	if runner.node.brain != null:
		action = runner.node.brain.get_end_of_rail_action()
	match action:
		Brain.EndOfRailAction.GOAL:
			_finish_runner_at_goal(runner)
		Brain.EndOfRailAction.PARK:
			_park_runner_at_finish(runner)
		Brain.EndOfRailAction.RESPAWN:
			_respawn_runner_at_start(runner)


func _finish_runner_at_goal(runner: Runner) -> void:
	runner.finished = true
	# Same-pool boarding: the player races the greeters for slots. Claim is
	# optional — `reach_goal()` still fires the cinematic either way. Win
	# vs fail is gated downstream on `train.is_boarded(player)`.
	_try_board_train(runner)
	runner.node.reach_goal()


# End-of-rail handler for FORWARD pawns whose end action is PARK (greeters).
# Boards if a slot is free; otherwise freezes at end of rail. The spawn cap
# in `_spawn_starting_npcs` makes "no slot" a player-only edge in normal
# play, since forward-NPC count is bounded by `train.slot_count`.
func _park_runner_at_finish(runner: Runner) -> void:
	runner.finished = true
	runner.segment_index = _corners.size() - 2
	runner.distance_along = _runner_segment_length(runner)
	if _try_board_train(runner):
		return
	# Fallback: no train present, or all slots filled. Stop at end of rail.
	runner.node.park_at_finish(Vector3.ZERO)
	_apply_runner_position(runner)
	_apply_runner_yaw_instant(runner)


# Resolve the level's Train and claim a slot for `runner`. On success the
# Pawn tweens onto the marker (Pawn.board) and reparents under it — train
# motion then carries the pawn via tree-transform inheritance.
# Returns true iff a slot was claimed.
func _try_board_train(runner: Runner) -> bool:
	var train: Train = get_tree().get_first_node_in_group("train") as Train
	if train == null:
		return false
	var marker: Marker3D = train.claim_slot(runner.node)
	if marker == null:
		return false
	runner.node.board(marker)
	return true


func _respawn_runner_at_start(runner: Runner) -> void:
	runner.segment_index = 0
	runner.distance_along = randf() * NPC_RESPAWN_STAGGER
	runner.node.set_current_lane(randi() % Pawn.LANE_COUNT)
	# Avoid landing on a same-lane peer near the spawn end (would mutual-lock
	# via speed modulation). Same helper `_register_pawn` uses at startup.
	var min_gap: float = runner.node.brain.get_min_peer_gap() if runner.node.brain != null else 1.0
	_destagger_runner_spawn(runner, min_gap)
	_apply_runner_position(runner)
	_apply_runner_yaw_instant(runner)


# Rail-coordinate encounter scan. Replaces the per-pawn forward RayCast3D that
# used to live on Pawn (ShuffleCast). For every RUNNING runner with a non-zero
# encounter_lookahead, finds the nearest other runner that is:
#   - on the same target lane (matches the obstacle scan's lane convention),
#   - ahead along the runner's travel direction,
#   - within encounter_lookahead rail-meters,
#   - not the runner's `shuffle_ignored` Pawn.
# Emits encounter_detected on the runner's Pawn with the rail-distance.
# Also clears `shuffle_ignored` once the ignored pawn is past the hysteresis
# margin (different lane / behind / further than lookahead + ENCOUNTER_IGNORE_HYSTERESIS).
func _scan_encounters_for_all_runners() -> void:
	if _runners.size() < 2:
		# Still try to clear stale ignores even with a single runner.
		for runner: Runner in _runners:
			if runner.shuffle_ignored != null:
				runner.shuffle_ignored = null
		return

	var snaps: Array[EncounterSnap] = []
	for runner: Runner in _runners:
		if not is_instance_valid(runner.node):
			continue
		var snap: EncounterSnap = EncounterSnap.new()
		snap.runner = runner
		snap.centerline = _runner_centerline_position(runner)
		# Occupied lane based on rounded `_lane_position` — see
		# `_runner_occupied_lane`. Tweening pawns count as occupying the
		# lane their body actually overlaps right now (not the target lane);
		# the engagement rule waits until both pawns settle before locking
		# into a shuffle.
		snap.lane = _runner_occupied_lane(runner)
		# Only RUNNING pawns initiate scans. Paused / knocked-down / disabled
		# runners stay in the snapshot list as candidate "others" but won't
		# emit encounter_detected themselves.
		snap.lookahead = runner.node.get_encounter_lookahead() if runner.node.is_running() else 0.0
		snaps.append(snap)

	for self_snap: EncounterSnap in snaps:
		if self_snap.lookahead > 0.0:
			var nearest_other: EncounterSnap = null
			var nearest_distance: float = INF
			for other_snap: EncounterSnap in snaps:
				if other_snap == self_snap:
					continue
				if other_snap.runner.node == self_snap.runner.shuffle_ignored:
					continue
				if other_snap.lane != self_snap.lane:
					continue
				var ahead: float = _signed_distance_ahead(
					self_snap.centerline,
					other_snap.centerline,
					self_snap.runner.toward_finish
				)
				if ahead <= 0.0 or ahead > self_snap.lookahead:
					continue
				if ahead < nearest_distance:
					nearest_distance = ahead
					nearest_other = other_snap
			if nearest_other != null:
				self_snap.runner.node.encounter_detected.emit(nearest_other.runner.node, nearest_distance)
		_maybe_clear_runner_ignore(self_snap, snaps)

	# Pass-detection second-pass: per-pair PassState phase machine + input gate.
	for self_snap: EncounterSnap in snaps:
		var self_pawn: Pawn = self_snap.runner.node
		var radius: float = self_pawn.get_pass_radius()
		if radius <= 0.0:
			self_snap.runner.tracked_passes.clear()
			continue
		if not self_pawn.is_running():
			# Preserve dict across SHUFFLING so TRIGGERED phase survives.
			continue
		var qualify_radius: float = self_pawn.get_pass_qualify_radius()
		var new_tracked: Dictionary[Pawn, PassState] = {}
		for other_snap: EncounterSnap in snaps:
			if other_snap == self_snap:
				continue
			if other_snap.runner.toward_finish == self_snap.runner.toward_finish:
				continue
			var other_node: Pawn = other_snap.runner.node
			var ahead: float = _signed_distance_ahead(
				self_snap.centerline,
				other_snap.centerline,
				self_snap.runner.toward_finish
			)
			if ahead > 0.0 and ahead <= radius:
				var state: PassState
				if self_snap.runner.tracked_passes.has(other_node):
					state = self_snap.runner.tracked_passes[other_node]
				else:
					state = PassState.new()
				if state.phase == PassState.Phase.TRACKED:
					var threat_now: bool = (
						qualify_radius <= 0.0
						or (other_snap.lane == self_snap.lane and ahead <= qualify_radius)
					)
					if threat_now:
						state.phase = PassState.Phase.QUALIFIED
				new_tracked[other_node] = state
			elif ahead <= 0.0 and ahead >= -radius:
				if self_snap.runner.tracked_passes.has(other_node):
					var existing: PassState = self_snap.runner.tracked_passes[other_node]
					if existing.phase == PassState.Phase.QUALIFIED and existing.had_input:
						self_pawn.runner_passed.emit(other_node)
		self_snap.runner.tracked_passes = new_tracked


# Distance from `self_pos` to `other_pos` along the runner's travel direction.
# Positive = `other` is ahead; <= 0 = behind or coincident.
func _signed_distance_ahead(self_pos: float, other_pos: float, self_toward_finish: bool) -> float:
	if self_toward_finish:
		return other_pos - self_pos
	return self_pos - other_pos


# Clear `runner.shuffle_ignored` when the ignored pawn is no longer a same-lane
# threat. Conditions for clearing:
#   - ignored pawn no longer in the active runner set,
#   - different lane,
#   - behind us (ahead <= 0),
#   - or further than encounter_lookahead + ENCOUNTER_IGNORE_HYSTERESIS.
func _maybe_clear_runner_ignore(self_snap: EncounterSnap, snaps: Array[EncounterSnap]) -> void:
	if self_snap.runner.shuffle_ignored == null:
		return
	var ignored_pawn: Pawn = self_snap.runner.shuffle_ignored
	var ignored_snap: EncounterSnap = null
	for s: EncounterSnap in snaps:
		if s.runner.node == ignored_pawn:
			ignored_snap = s
			break
	if ignored_snap == null:
		self_snap.runner.shuffle_ignored = null
		return
	if ignored_snap.lane != self_snap.lane:
		self_snap.runner.shuffle_ignored = null
		return
	var ahead: float = _signed_distance_ahead(
		self_snap.centerline,
		ignored_snap.centerline,
		self_snap.runner.toward_finish
	)
	if ahead <= 0.0:
		self_snap.runner.shuffle_ignored = null
		return
	if ahead > self_snap.lookahead + ENCOUNTER_IGNORE_HYSTERESIS:
		self_snap.runner.shuffle_ignored = null


# Scan the runner's current lane for an obstacle within their lookahead. When
# something is hit, emit obstacle_detected on the pawn — the Brain decides
# what to do (PlayerBrain blocks; AIBrain runs `_pick_clear_lane`, which
# gates each candidate through `pawn.can_enter_lane` for both obstacle and
# peer occupancy).
func _detect_obstacle_and_notify_brain(runner: Runner) -> void:
	var lookahead: float = runner.node.get_obstacle_lookahead()
	if lookahead <= 0.0:
		return
	var current_lane: int = runner.node.get_current_lane()
	var blocker: Node = _scan_lane_for_obstacle(runner, current_lane, lookahead)
	if blocker == null:
		return
	runner.node.obstacle_detected.emit(blocker, lookahead, current_lane)


# Public: nearest other Pawn ahead of `querier` in `lane` (querier's
# direction-relative frame), within [0, lookahead] rail-meters. Null if none.
# Internally compares physical (world-side) lanes so FORWARD vs REVERSE doesn't
# false-match. Used by AIBrain for clearance-aware lane choice and by
# `Pawn.can_enter_lane` (via `get_lane_clearance`) for the lane-change gate.
#
# Keys on TARGET lane (`_runner_target_lane`) — a peer mid-tween 0→1 reports
# as in lane 1 (their target). This is LANE-RESERVATION semantics: a peer
# committing into lane X claims lane X for the gate, so two pawns never plan
# into the same lane simultaneously. The encounter scan
# (`_scan_encounters_for_all_runners`) keys on OCCUPIED instead because it
# asks a different question — physical-overlap collision prediction. DO NOT
# unify the two; the asymmetry is load-bearing. See `_runner_occupied_lane`
# for the parallel rationale.
func find_lane_occupant_ahead(querier: Pawn, lane: int, lookahead: float) -> Pawn:
	var querier_runner: Runner = _find_runner_for(querier)
	if querier_runner == null:
		return null
	var query_physical_lane: int = _physical_lane_for(querier_runner, lane)
	var querier_centerline: float = _runner_centerline_position(querier_runner)
	var nearest: Pawn = null
	var nearest_distance: float = INF
	for other: Runner in _runners:
		if other == querier_runner:
			continue
		if not is_instance_valid(other.node):
			continue
		if _runner_target_lane(other) != query_physical_lane:
			continue
		var ahead: float = _signed_distance_ahead(
			querier_centerline,
			_runner_centerline_position(other),
			querier_runner.toward_finish
		)
		if ahead <= 0.0 or ahead > lookahead:
			continue
		if ahead < nearest_distance:
			nearest_distance = ahead
			nearest = other.node
	return nearest


# Compression-scan sibling of `find_lane_occupant_ahead`: matches a peer whose
# either TARGET or OCCUPIED lane equals `lane`. Catches mid-tween peers the
# target-only scan misses (peer tweening OUT keeps their body in our lane for
# ~0.3 s after their target flips). Lane-reservation queries still use the
# target-only sibling — keep the split.
func find_lane_occupant_ahead_compression(querier: Pawn, lane: int, lookahead: float) -> Pawn:
	var querier_runner: Runner = _find_runner_for(querier)
	if querier_runner == null:
		return null
	var query_physical_lane: int = _physical_lane_for(querier_runner, lane)
	var querier_centerline: float = _runner_centerline_position(querier_runner)
	var nearest: Pawn = null
	var nearest_distance: float = INF
	for other: Runner in _runners:
		if other == querier_runner:
			continue
		if not is_instance_valid(other.node):
			continue
		var target_match: bool = _runner_target_lane(other) == query_physical_lane
		var occupied_match: bool = _runner_occupied_lane(other) == query_physical_lane
		if not target_match and not occupied_match:
			continue
		var ahead: float = _signed_distance_ahead(
			querier_centerline,
			_runner_centerline_position(other),
			querier_runner.toward_finish
		)
		if ahead <= 0.0 or ahead > lookahead:
			continue
		if ahead < nearest_distance:
			nearest_distance = ahead
			nearest = other.node
	return nearest


# Signed rail-distance from `querier` to `peer` in querier's travel direction.
# Positive = ahead; <= 0 = behind. INF if either is unregistered.
func get_rail_distance_to_peer(querier: Pawn, peer: Pawn) -> float:
	var querier_runner: Runner = _find_runner_for(querier)
	var peer_runner: Runner = _find_runner_for(peer)
	if querier_runner == null or peer_runner == null:
		return INF
	return _signed_distance_ahead(
		_runner_centerline_position(querier_runner),
		_runner_centerline_position(peer_runner),
		querier_runner.toward_finish
	)


# Public: every RUNNING peer ahead of `querier` within `lookahead` rail-meters
# in ANY lane. Excludes querier itself, parked / finished / disabled pawns,
# and any pawn currently in querier's `shuffle_ignored` slot. Brains read
# peers' `lean_direction` and `get_current_lane()` directly to bias lane
# choices against pawns committing into the same lane.
func get_runners_near(querier: Pawn, lookahead: float) -> Array[Pawn]:
	var querier_runner: Runner = _find_runner_for(querier)
	if querier_runner == null:
		return []
	var querier_centerline: float = _runner_centerline_position(querier_runner)
	var ignored: Pawn = querier_runner.shuffle_ignored
	var result: Array[Pawn] = []
	for other: Runner in _runners:
		if other == querier_runner:
			continue
		if not is_instance_valid(other.node):
			continue
		if other.finished:
			continue
		if other.node == ignored:
			continue
		# Skip non-RUNNING peers: their lean / target_lane is stale (they're
		# parked, knocked down, sidestepping, etc.) so factoring them into
		# clearance just adds noise.
		if other.node.locomotion != Pawn.LocomotionState.RUNNING:
			continue
		var ahead: float = _signed_distance_ahead(
			querier_centerline,
			_runner_centerline_position(other),
			querier_runner.toward_finish
		)
		if ahead <= 0.0 or ahead > lookahead:
			continue
		result.append(other.node)
	return result


# Public: clearance ahead in `lane` (querier's direction-relative frame), in
# rail-meters. Returns 0 if the lane has an obstacle within lookahead, else
# the distance to the nearest occupant ahead, or `lookahead` if the lane is
# fully clear. Used by `Pawn.can_enter_lane` (the canonical lane-change gate)
# and by `Brain.modulate_for_same_direction_peer` (convoy speed matching).
# Inherits `find_lane_occupant_ahead`'s TARGET-lane keying — see its
# docstring for why this differs from the encounter scan.
func get_lane_clearance(querier: Pawn, lane: int, lookahead: float) -> float:
	var querier_runner: Runner = _find_runner_for(querier)
	if querier_runner == null:
		return 0.0
	if _scan_lane_for_obstacle(querier_runner, lane, lookahead) != null:
		return 0.0
	var occupant: Pawn = find_lane_occupant_ahead(querier, lane, lookahead)
	if occupant == null:
		return lookahead
	var occupant_runner: Runner = _find_runner_for(occupant)
	if occupant_runner == null:
		return lookahead
	return _signed_distance_ahead(
		_runner_centerline_position(querier_runner),
		_runner_centerline_position(occupant_runner),
		querier_runner.toward_finish
	)


# True iff `pawn` is within `margin` rail-meters of an INTERIOR corner — an
# actual turn — and not just the start (`corners[0]`) or finish
# (`corners[size-1]`), which never snap. Used by AIBrain to suppress overtake
# and random-lane-change near corners, where the perpendicular lane offset
# re-bases against the new segment direction (~sqrt(2)*lane_offset world-space
# snap for 90° turns); initiating a tween across that boundary cascades into
# traffic jams as multiple peers all re-rank lanes post-snap and converge on
# the same "safer" slot. Obstacle dodge and shuffle stance are NOT gated on
# this — both remain ungated in their respective handlers.
#
# Direction-agnostic: `runner.segment_index` is direction-relative (init param,
# advances on every segment cross regardless of FORWARD/REVERSE), so a single
# pair of bounds checks covers both travel directions. Returns false when
# `margin <= 0` (caller-side disable), the pawn is unregistered, or no
# interior corner is within range.
func is_runner_near_corner(pawn: Pawn, margin: float) -> bool:
	if margin <= 0.0:
		return false
	var runner: Runner = _find_runner_for(pawn)
	if runner == null:
		return false
	# Approaching an interior corner ahead. Last segment ends at the finish
	# (`corners[size-1]`) which is not a turn — exclude.
	if runner.segment_index < _corners.size() - 2:
		var seg_length: float = _runner_segment_length(runner)
		if seg_length - runner.distance_along < margin:
			return true
	# Just past an interior corner behind. Segment 0 starts at the rail start
	# (`corners[0]`) which is not a turn — exclude.
	if runner.segment_index > 0:
		if runner.distance_along < margin:
			return true
	return false


# Convert a runner's direction-relative lane index to physical (world-side).
# Symmetric inverse of _runner_target_lane. Pulled out so external queries
# can pass direction-relative lanes without knowing the runner's orientation.
func _physical_lane_for(runner: Runner, direction_relative_lane: int) -> int:
	if runner.toward_finish:
		return direction_relative_lane
	return (Pawn.LANE_COUNT - 1) - direction_relative_lane


# Sample positions ahead along the runner's rail in a candidate lane. Returns
# the first `obstacle` group node in the path, or null if clear.
#
# Sampling spans `[base_distance, base_distance + lookahead]` inclusive (5
# rays for sample_count=4). The leading `i=0` sample covers the immediate
# vicinity — the perpendicular point right next to the runner. Without it,
# `can_enter_lane`'s 1.5 m scan has a [0, 0.375 m) dead zone, while the
# obstacle scan in the runner's current lane (0.75 m for player) catches
# anything past 0.1875 m — the band [0.1875, 0.375] m would let the swerve
# gate pass and then block the runner the very next frame ("swerve and
# stop"). 5 samples close the gap.
func _scan_lane_for_obstacle(runner: Runner, lane: int, lookahead: float) -> Node:
	var space_state: PhysicsDirectSpaceState3D = runner.node.get_world_3d().direct_space_state
	if space_state == null:
		return null
	var sample_count: int = 4
	var step: float = lookahead / float(sample_count)
	var base_distance: float = runner.distance_along
	for i: int in range(sample_count + 1):
		var sample_distance: float = base_distance + step * float(i)
		var sample: Vector3 = _runner_position_at(runner, lane, sample_distance)
		var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
			sample + Vector3.UP * (OBSTACLE_RAY_HEIGHT + 0.5),
			sample + Vector3.UP * (OBSTACLE_RAY_HEIGHT - 0.5)
		)
		query.exclude = [runner.node.get_rid()]
		query.collide_with_bodies = true
		var hit: Dictionary = space_state.intersect_ray(query)
		if hit.is_empty():
			continue
		var collider: Object = hit.get("collider")
		if collider is Node and (collider as Node).is_in_group("obstacle"):
			return collider as Node
	return null


# Project a world position for a runner walking a given lane at a given
# distance offset within the current segment (clamps if the offset overruns).
func _runner_position_at(runner: Runner, lane: int, distance_along: float) -> Vector3:
	var seg_start: Vector3 = _runner_lane_segment_start(runner.segment_index, lane, runner.toward_finish)
	var seg_end: Vector3 = _runner_lane_segment_end(runner.segment_index, lane, runner.toward_finish)
	var seg_dir: Vector3 = seg_end - seg_start
	seg_dir.y = 0.0
	if seg_dir.length_squared() < 0.001:
		return seg_start
	var seg_length: float = seg_dir.length()
	seg_dir = seg_dir / seg_length
	var clamped: float = clampf(distance_along, 0.0, seg_length)
	return seg_start + seg_dir * clamped


# Write the runner's world position from its segment + distance + lane.
# Lane floor/ceil interpolation works for any runner — when the lane tween is
# inactive get_lane_position() returns the integer target lane (t == 0), so
# the ceil branch is skipped and the result matches a clean snap. Parked
# pawns layer their authored offset on top.
func _apply_runner_position(runner: Runner) -> void:
	var distance_along: float = runner.distance_along
	var lane_pos: float = runner.node.get_lane_position()
	var lane_floor: int = clampi(floori(lane_pos), 0, LANE_OFFSETS.size() - 1)
	var t: float = clampf(lane_pos - float(lane_floor), 0.0, 1.0)
	var pos: Vector3 = _runner_position_at(runner, lane_floor, distance_along)
	if t > 0.001:
		var lane_ceil: int = clampi(lane_floor + 1, 0, LANE_OFFSETS.size() - 1)
		pos = pos.lerp(_runner_position_at(runner, lane_ceil, distance_along), t)
	if runner.node.locomotion == Pawn.LocomotionState.PARKED:
		pos += runner.node.get_parked_offset()
	pos.y = runner.node.global_position.y
	runner.node.global_position = pos


# Smoothly rotate the runner toward its current rail direction. Yaw is
# lane-independent now (every lane in a segment shares forward direction), so
# this is a single lookup + frame-rate smoothing.
func _apply_runner_yaw(runner: Runner, delta: float) -> void:
	var turn_weight: float = clampf(TURN_WEIGHT * delta, 0.0, 1.0)
	runner.node.rotation.y = lerp_angle(runner.node.rotation.y, _runner_segment_yaw(runner), turn_weight)


# Snap the runner's yaw to the current rail direction without easing.
func _apply_runner_yaw_instant(runner: Runner) -> void:
	runner.node.rotation.y = _runner_segment_yaw(runner)


# Yaw direction the runner should face right now.
#
# Default: rail forward in the runner's current segment. Lane-independent
# (see _runner_segment_length). Returns pawn's current yaw on a degenerate
# segment so lerp_angle doesn't snap.
#
# Override during SHUFFLING: face the shuffle opponent directly, ignoring the
# rail. On corners the rail forward kinks but the encounter geometry (the two
# bodies closing on each other) doesn't — so we orient toward the peer
# instead. The PlayerCamera tracks `target_pawn.rotation.y` every frame
# (`pawn_camera.gd:124`), so the player view inherits this without any
# camera-side change. After resolution: winner returns to RUNNING and
# `_apply_runner_yaw`'s lerp glides yaw back to rail forward (TURN_WEIGHT
# time-constant ~100 ms wall-clock, ~500 ms during bullet-time which only
# matters mid-shuffle anyway). Loser is KNOCKED_DOWN — `is_advancing_paused`
# excludes them from `_advance_runner`, so their yaw freezes facing the
# winner as they fall, which reads cinematically.
func _runner_segment_yaw(runner: Runner) -> float:
	if runner.node.locomotion == Pawn.LocomotionState.SHUFFLING:
		var other: Pawn = runner.node.get_shuffle_other()
		if other != null:
			var to_other: Vector3 = other.global_position - runner.node.global_position
			to_other.y = 0.0
			if to_other.length_squared() > 0.001:
				return atan2(-to_other.x, -to_other.z)
	var seg_start: Vector3 = _runner_lane_segment_start(runner.segment_index, 0, runner.toward_finish)
	var seg_end: Vector3 = _runner_lane_segment_end(runner.segment_index, 0, runner.toward_finish)
	var fwd: Vector3 = seg_end - seg_start
	fwd.y = 0.0
	if fwd.length_squared() < 0.001:
		return runner.node.rotation.y
	fwd = fwd.normalized()
	return atan2(-fwd.x, -fwd.z)


# Rewind any runner along the rail when they are knocked down. The pawn's
# brain config governs how far back they end up, so the player and NPCs can
# have different recoil tuning by swapping configs.
#
# Chain reaction: before we rewind, propagate the knockdown to any
# same-direction peer behind us in the same target lane within the requested
# rewind distance. Their `knock_down_from_shuffle()` emits `knocked_down`
# synchronously, which re-enters this handler for that pawn and cascades
# until no further chain target exists. By the time our `_rewind_runner` runs,
# every chained peer has already moved backward, so the existing
# `_clamp_rewind_to_rear_pawn` logic re-queries their NEW positions and
# yields a clean buffered separation with no overlap math here.
func _on_runner_knocked_down(runner: Runner) -> void:
	var knockback: float = runner.node.brain.get_shuffle_knockback_distance() if runner.node.brain != null else 0.0
	_propagate_knockback_chain(runner, knockback)
	_rewind_runner(runner, knockback)
	_apply_runner_position(runner)


# Trigger knock_down_from_shuffle on the nearest same-direction peer behind
# `runner` within `distance` rail-meters. Pawn.knock_down_from_shuffle is
# idempotent (no-op on KNOCKED_DOWN) and emits `knocked_down` synchronously,
# so the recursion bottoms out naturally when _find_chain_target returns null.
func _propagate_knockback_chain(runner: Runner, distance: float) -> void:
	if distance <= 0.0:
		return
	var rear: Runner = _find_chain_target(runner, distance)
	if rear == null:
		return
	rear.node.knock_down_from_shuffle()


# Nearest same-direction, same-target-lane peer behind `runner` within
# `distance` rail-meters that is in a state we can chain into (RUNNING or
# SHUFFLING). Skips KNOCKED_DOWN / PARKED / FINISHED / DISABLED — those are
# either already part of an active chain or shouldn't be disturbed. Returns
# the Runner or null if no chain target exists.
func _find_chain_target(runner: Runner, distance: float) -> Runner:
	var target_lane: int = _runner_target_lane(runner)
	var center: float = _runner_centerline_position(runner)
	var nearest: Runner = null
	var nearest_behind: float = INF
	for other: Runner in _runners:
		if other == runner or not is_instance_valid(other.node):
			continue
		if other.toward_finish != runner.toward_finish:
			continue
		if _runner_target_lane(other) != target_lane:
			continue
		var loco: int = other.node.locomotion
		if loco != Pawn.LocomotionState.RUNNING and loco != Pawn.LocomotionState.SHUFFLING:
			continue
		var ahead: float = _signed_distance_ahead(
			center, _runner_centerline_position(other), runner.toward_finish
		)
		# Negative `ahead` = peer is behind us along travel direction.
		if ahead >= 0.0:
			continue
		var behind: float = -ahead
		if behind > distance:
			continue
		if behind < nearest_behind:
			nearest_behind = behind
			nearest = other
	return nearest


# Rewind a runner backward along the rail by the given distance, clamped so
# we don't pass through (or land on top of) a same-target-lane pawn behind
# us. If a peer is closer behind than the requested rewind, the rewind is
# capped at that peer's distance minus a small buffer (KNOCKBACK_REAR_BUFFER)
# so the two pawns don't end up coincident and lock each other via mutual
# speed-modulation.
func _rewind_runner(runner: Runner, distance: float) -> void:
	var clamped: float = _clamp_rewind_to_rear_pawn(runner, distance)
	var remaining: float = maxf(clamped, 0.0)
	while remaining > 0.0:
		if runner.distance_along >= remaining:
			runner.distance_along -= remaining
			return
		remaining -= runner.distance_along
		if runner.segment_index <= 0:
			runner.distance_along = 0.0
			return
		runner.segment_index -= 1
		runner.distance_along = _runner_segment_length(runner)


# Clamp `distance` to the rail-distance to the nearest same-target-lane
# pawn BEHIND `runner` (in runner's travel direction), minus
# KNOCKBACK_REAR_BUFFER so the post-rewind position isn't coincident. Returns
# `distance` unchanged when no rear pawn is within the requested rewind.
func _clamp_rewind_to_rear_pawn(runner: Runner, distance: float) -> float:
	if distance <= 0.0:
		return 0.0
	var target_lane: int = _runner_target_lane(runner)
	var center: float = _runner_centerline_position(runner)
	var nearest_behind: float = INF
	for other: Runner in _runners:
		if other == runner or not is_instance_valid(other.node):
			continue
		if _runner_target_lane(other) != target_lane:
			continue
		var ahead: float = _signed_distance_ahead(
			center, _runner_centerline_position(other), runner.toward_finish
		)
		# Negative `ahead` = peer is behind us along travel direction.
		if ahead >= 0.0:
			continue
		var behind: float = -ahead
		if behind < nearest_behind:
			nearest_behind = behind
	if nearest_behind == INF:
		return distance
	return minf(distance, maxf(0.0, nearest_behind - KNOCKBACK_REAR_BUFFER))


# Lane start point on a directed segment.
# For reverse runners we walk corners in reverse order and flip the lane index
# so "lane 0" stays the same world side regardless of travel direction.
func _runner_lane_segment_start(segment_index: int, lane: int, toward_finish: bool) -> Vector3:
	if not toward_finish:
		var reversed_index: int = (_corners.size() - 2) - segment_index
		var flipped_lane: int = (Pawn.LANE_COUNT - 1) - lane
		return _get_lane_segment_end(reversed_index, flipped_lane)
	return _get_lane_segment_start(segment_index, lane)


# Lane end point on a directed segment.
func _runner_lane_segment_end(segment_index: int, lane: int, toward_finish: bool) -> Vector3:
	if not toward_finish:
		var reversed_index: int = (_corners.size() - 2) - segment_index
		var flipped_lane: int = (Pawn.LANE_COUNT - 1) - lane
		return _get_lane_segment_start(reversed_index, flipped_lane)
	return _get_lane_segment_end(segment_index, lane)


# Get the lane-specific start point for a segment.
# Lane offset is perpendicular to THIS segment's direction. The previous
# implementation used _get_lane_turn_point (intersection of in/out lane lines
# at interior corners), which baked a parallel-to-rail component into non-center
# lanes — strafing right after a right turn moved the player forward along the
# rail. Uniform perpendicular offset costs the per-lane corner-tracking
# geometry (outer lanes no longer take longer paths around corners, and lanes
# 0/2 visibly snap by ~sqrt(2)*offset across each interior corner) but fixes
# the strafe direction throughout each segment.
func _get_lane_segment_start(segment_index: int, lane: int) -> Vector3:
	return _get_lane_endpoint(segment_index, segment_index, segment_index + 1, lane)


# Get the lane-specific end point for a segment. See _get_lane_segment_start
# for the rationale on perpendicular-to-segment offsets vs lane turn points.
func _get_lane_segment_end(segment_index: int, lane: int) -> Vector3:
	return _get_lane_endpoint(segment_index + 1, segment_index, segment_index + 1, lane)


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
