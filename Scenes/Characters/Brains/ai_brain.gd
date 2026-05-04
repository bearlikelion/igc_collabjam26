class_name AIBrain
extends Brain

# AI brain. Owns all rail-movement intent for an NPC: destination, speed, lane
# avoidance. MetroMovement queries these via the Brain virtual interface on Pawn.
# Timer-driven lane decisions tick through physics_tick (no Timer nodes — Brain
# is a Resource and cannot have child nodes).

@export_group("Rail")
## Group name of the node this NPC walks toward. "finish" for same-direction
## runners, "player" for oncoming traffic. Resolved to a Node3D at bind time.
@export var destination_group: StringName = &"finish"
@export var spawn_distance: float = 0.0
@export var move_speed: float = 1.8
@export_range(0.0, 1.0, 0.01) var move_speed_variance: float = 0.3

@export_group("Lane Behavior")
@export var avoid_obstacles: bool = true
@export var obstacle_lookahead: float = 2.0
@export var avoidance_cooldown: float = 2.0

@export_group("Encounters")
## Rail-distance the encounter scan looks ahead for other Pawns in the same
## lane. NPCs use this to swerve around paused / NPC traffic; active players
## are passed through (see _on_encounter_detected).
@export var encounter_lookahead: float = 2.0

@export_group("Random Lane")
@export var random_lane_changes: bool = false
@export_range(0.5, 30.0, 0.5) var random_lane_interval_min: float = 3.0
@export_range(0.5, 30.0, 0.5) var random_lane_interval_max: float = 7.0

var destination: Node3D
var _actual_move_speed: float = 0.0
var _next_random_lane_msec: int = 0
var _avoidance_until_msec: int = 0


# --- Brain hooks ----------------------------------------------------------

func _on_bound() -> void:
	pawn.add_to_group("npc")
	destination = pawn.get_tree().get_first_node_in_group(destination_group)
	_roll_speed()
	if random_lane_changes:
		_next_random_lane_msec = Time.get_ticks_msec() + int(_next_random_lane_delay() * 1000.0)


func physics_tick(_delta: float) -> void:
	if not random_lane_changes:
		return
	if Time.get_ticks_msec() < _next_random_lane_msec:
		return
	var clear_lane: int = _pick_random_other_lane(pawn.get_current_lane())
	if clear_lane != pawn.get_current_lane():
		pawn.request_lane_change(clear_lane)
	_next_random_lane_msec = Time.get_ticks_msec() + int(_next_random_lane_delay() * 1000.0)


func _on_encounter_detected(other: Pawn, _distance: float) -> void:
	if other == null:
		return
	# NPCs don't initiate shuffles. Swerve only if the other can't react
	# (knocked-down player) or another NPC blocking the lane. An active player
	# keeps holding the lane so the player's dodge mechanic still triggers.
	if not other.is_in_group("npc") and not other.is_runner_paused():
		return
	if Time.get_ticks_msec() < _avoidance_until_msec:
		return
	var clear_lane: int = _pick_random_other_lane(pawn.get_current_lane())
	if clear_lane != pawn.get_current_lane():
		pawn.request_lane_change(clear_lane)
		_avoidance_until_msec = Time.get_ticks_msec() + int(avoidance_cooldown * 1000.0)


# Environment obstacle in the current lane — swerve to a candidate lane.
# Candidates arrive pre-shuffled and pre-filtered to clear lanes only, so
# picking the first one is a uniform random choice among the safe options.
func _on_obstacle_detected(_blocker: Node, _distance: float, _in_lane: int, candidate_lanes: Array[int]) -> void:
	if Time.get_ticks_msec() < _avoidance_until_msec:
		return
	if candidate_lanes.is_empty():
		return
	pawn.request_lane_change(candidate_lanes[0])
	_avoidance_until_msec = Time.get_ticks_msec() + int(avoidance_cooldown * 1000.0)


func _on_shuffle_began(_other: Pawn, _other_telegraph: int, _deadline_msec: int) -> void:
	# Roll a random direction. Future archetypes can override for variety.
	var direction: int = -1 if randf() < 0.5 else 1
	pawn.lean(direction)
	pawn.set_shuffle_telegraph(direction)


# --- Brain virtuals -------------------------------------------------------

func get_destination() -> Node3D:
	return destination


func get_move_speed() -> float:
	if _actual_move_speed <= 0.0:
		_roll_speed()
	return _actual_move_speed


func get_spawn_distance() -> float:
	return spawn_distance


func should_avoid_obstacles() -> bool:
	return avoid_obstacles


func get_obstacle_lookahead() -> float:
	return obstacle_lookahead


func get_encounter_lookahead() -> float:
	return encounter_lookahead


# Forward NPCs (destination = "finish") park as greeters at the end of the
# rail. Reverse NPCs (destination = "player" or anything else) loop back to
# the start so a fresh oncoming runner appears.
func get_end_of_rail_action() -> int:
	if destination_group == &"finish":
		return EndOfRailAction.PARK
	return EndOfRailAction.RESPAWN



# --- Helpers --------------------------------------------------------------

func _roll_speed() -> void:
	var jitter: float = (randf() * 2.0 - 1.0) * move_speed_variance
	_actual_move_speed = maxf(0.1, move_speed * (1.0 + jitter))


func _pick_random_other_lane(current: int) -> int:
	if Pawn.LANE_COUNT <= 1:
		return current
	var choices: Array[int] = []
	for lane: int in range(Pawn.LANE_COUNT):
		if lane != current:
			choices.append(lane)
	if choices.is_empty():
		return current
	return choices[randi() % choices.size()]


func _next_random_lane_delay() -> float:
	var lo: float = minf(random_lane_interval_min, random_lane_interval_max)
	var hi: float = maxf(random_lane_interval_min, random_lane_interval_max)
	if hi <= 0.0:
		return 1.0
	return lo + randf() * maxf(hi - lo, 0.0)
