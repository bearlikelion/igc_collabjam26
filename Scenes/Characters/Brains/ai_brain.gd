class_name AIBrain
extends Brain

# AI brain. Owns all rail-movement intent for an NPC: destination, speed, lane
# avoidance. MetroMovement queries these via the Brain virtual interface on Pawn.
# Timer-driven lane decisions tick through physics_tick using msec timestamps —
# avoids spawning Timer child nodes and keeps all decision state in one place.

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
## Minimum clearance (rail-meters) a candidate lane must offer before this AI
## will swerve into it. If no candidate clears the floor, the AI holds its
## current lane rather than swap into a tighter slot.
@export var min_clearance: float = 1.5

@export_group("Encounters")
## Rail-distance the encounter scan looks ahead for other Pawns in the same
## lane. NPCs use this to swerve around paused / NPC traffic; active players
## are passed through (see _on_encounter_detected).
@export var encounter_lookahead: float = 2.0
## Rail-meters of clearance penalty applied per peer who is leaning INTO a
## candidate lane. Higher = more cautious (AI avoids lanes that peers are
## committing toward, even if currently empty). 0 = ignore peer leans.
@export_range(0.0, 5.0, 0.1) var lean_threat_weight: float = 1.0
## Probability this AI stays in its lane (commits 0, no lean) when a player
## initiates a shuffle, forcing the player to commit ±1 to avoid collision.
## 0 = always commit a side. 1 = always stay. Only applies to player-vs-NPC.
## NPC-NPC encounters use deterministic clearance/opposite negotiation.
@export_range(0.0, 1.0, 0.05) var stay_in_lane_chance: float = 0.33

@export_group("Random Lane")
@export var random_lane_changes: bool = false
@export_range(0.5, 30.0, 0.5) var random_lane_interval_min: float = 3.0
@export_range(0.5, 30.0, 0.5) var random_lane_interval_max: float = 7.0

var destination: Node3D
var _actual_move_speed: float = 0.0
var _next_random_lane_msec: int = 0
var _avoidance_until_msec: int = 0

# Pawn we're stalled behind because they're busy in another shuffle. While
# set, get_move_speed returns 0 so this NPC visibly stops. Auto-clears as
# soon as the target's locomotion returns to RUNNING (checked in the getter).
# The encounter scan keeps firing each frame and re-attempts start_shuffle
# the moment the peer is free.
var _waiting_for: Pawn


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
	var clear_lane: int = _pick_clear_lane(pawn.get_current_lane())
	if clear_lane != pawn.get_current_lane():
		pawn.request_lane_change(clear_lane)
	_next_random_lane_msec = Time.get_ticks_msec() + int(_next_random_lane_delay() * 1000.0)


func _on_encounter_detected(other: Pawn, _distance: float) -> void:
	if other == null:
		return
	if Time.get_ticks_msec() < _avoidance_until_msec:
		return
	# Same-direction peer (player or NPC walking our way): no shuffle. Speed
	# modulation in get_move_speed caps us at their speed so we trail without
	# ever colliding. Knockback should only fire head-on.
	if other.is_routing_to_finish_point() == pawn.is_routing_to_finish_point():
		_waiting_for = null
		return
	# Active opposing player: do nothing — player's own brain initiates.
	if other.is_in_group("player") and not other.is_runner_paused():
		_waiting_for = null
		return
	# Active opposing NPC: negotiate via the shuffle protocol.
	if other.is_in_group("npc") and not other.is_runner_paused():
		_waiting_for = null
		pawn.start_shuffle(other)
		return
	# Busy opposing NPC (shuffling with someone else): stop and wait.
	# get_move_speed zeros out until the peer is RUNNING again. Encounter scan
	# keeps firing, so once the peer frees up the next call hits the active
	# branch.
	if other.is_in_group("npc"):
		_waiting_for = other
		pawn.run_speed = pawn.start_speed
		return
	# Paused opposing player (knocked down) — swerve sideways.
	var clear_lane: int = _pick_clear_lane(pawn.get_current_lane())
	if clear_lane != pawn.get_current_lane():
		pawn.request_lane_change(clear_lane)
		_avoidance_until_msec = Time.get_ticks_msec() + int(avoidance_cooldown * 1000.0)


# Environment obstacle in the current lane — swerve via the clearance ranker
# instead of trusting the signal's pre-shuffled candidates. The signal still
# carries them as an obstacle-only filter, but registry-aware ranking also
# considers other pawns and applies the min_clearance floor.
func _on_obstacle_detected(_blocker: Node, _distance: float, in_lane: int, _candidate_lanes: Array[int]) -> void:
	if Time.get_ticks_msec() < _avoidance_until_msec:
		return
	var clear_lane: int = _pick_clear_lane(in_lane)
	if clear_lane != in_lane:
		pawn.request_lane_change(clear_lane)
		_avoidance_until_msec = Time.get_ticks_msec() + int(avoidance_cooldown * 1000.0)


func _on_shuffle_began(other: Pawn, other_telegraph: int, _deadline_msec: int) -> void:
	if other == null:
		return
	if other.is_in_group("npc"):
		# NPC-NPC dispatch by role.
		# - Initiator: pick by lane clearance — we lane-change on resolution.
		# - Callee:    oppose initiator's pick. If initiator hasn't committed
		#              yet (other_telegraph == 0), pick a placeholder (+1);
		#              _on_shuffle_telegraph_changed re-evaluates on commit.
		var is_initiator: bool = pawn.shuffle != null and pawn.shuffle.is_initiator
		var direction: int = 0
		if is_initiator:
			direction = _clearer_direction()
		elif other_telegraph != 0:
			direction = _opposite_world_side(other, other_telegraph)
		else:
			direction = 1
		pawn.lean(direction)
		pawn.set_shuffle_telegraph(direction)
		return
	# Player path — three-way roll:
	#   stay (no lean, no telegraph): forces the player to commit ±1
	#   ±1 (lean visible, telegraph set): full bullet-time window to be read
	# `shuffle.my_telegraph` defaults to 0 from Pawn.begin_subway_shuffle, so
	# "stay" just means: don't call set_shuffle_telegraph / lean at all.
	if randf() < stay_in_lane_chance:
		return
	var direction: int = -1 if randf() < 0.5 else 1
	pawn.lean(direction)
	pawn.set_shuffle_telegraph(direction)


# Re-evaluate when the other party updates their telegraph mid-window.
# - NPC-NPC initiator: hold our clearance-based pick. The callee will converge.
# - NPC-NPC callee:    pick world-side OPPOSITE of initiator's commit.
# - Player path:       ignore — we already committed at shuffle start.
# Pawn.set_shuffle_telegraph guards against re-emit on same value, so the
# A→B→A handshake converges in ~2 iterations without ping-ponging.
func _on_shuffle_telegraph_changed(direction: int) -> void:
	if pawn.shuffle == null or pawn.shuffle.other == null:
		return
	var other: Pawn = pawn.shuffle.other
	if not other.is_in_group("npc"):
		return
	# Initiator drives the lane preference; ignore the callee's reactive
	# emit. Callee follows with opposite-world.
	if pawn.shuffle.is_initiator:
		return
	var our_direction: int = _opposite_world_side(other, direction)
	pawn.lean(our_direction)
	pawn.set_shuffle_telegraph(our_direction)


# Pick this AI's telegraph (-1 / +1) such that its world-space side points
# opposite to the other Pawn's chosen world-side. If the other hasn't
# committed yet (other_telegraph == 0), default to +1 — _on_shuffle_telegraph_changed
# will recompute when they commit.
func _opposite_world_side(other: Pawn, other_telegraph: int) -> int:
	if other_telegraph == 0:
		return 1
	var my_basis_x: Vector3 = pawn.global_transform.basis.x
	my_basis_x.y = 0.0
	var their_basis_x: Vector3 = other.global_transform.basis.x
	their_basis_x.y = 0.0
	if my_basis_x.length_squared() < 0.001 or their_basis_x.length_squared() < 0.001:
		# Degenerate basis — fall back to "different telegraph from theirs",
		# correct for the same-direction case (which should be the common one
		# when degenerate flat bases occur, e.g. straight rail segments).
		return -other_telegraph
	var their_side: Vector3 = their_basis_x.normalized() * float(other_telegraph)
	var my_side_plus: Vector3 = my_basis_x.normalized()
	if my_side_plus.dot(their_side) <= 0.0:
		return 1
	return -1


# NPC-NPC initiator helper: pick ±1 based on which adjacent lane is "safer"
# given current occupants AND nearby peers' leans. The initiator's resolution
# lane-changes by `direction`, so this lands us in the better lane.
# Score = clearance - sum(lean_threat_weight) for each peer leaning into the
# candidate lane. Higher score = safer.
# Edge cases:
#   - At lane 0: only +1 makes sense (clamps otherwise).
#   - At lane LANE_COUNT-1: only -1.
#   - Tie or no MetroMovement back-ref: default +1.
func _clearer_direction() -> int:
	var current: int = pawn.get_current_lane()
	var can_left: bool = current > 0
	var can_right: bool = current < Pawn.LANE_COUNT - 1
	if not can_left:
		return 1
	if not can_right:
		return -1
	if pawn._metro_movement == null:
		return 1
	var left_score: float = _lane_safety_score(current - 1)
	var right_score: float = _lane_safety_score(current + 1)
	return -1 if left_score > right_score else 1


# Combine raw clearance with lean-threat penalty. A peer's lean is "into"
# `candidate_lane` when their lane_direction implies a target equal to it —
# i.e. their target_lane + their lean_direction == candidate_lane.
# All lane comparisons are in the querier's direction-relative frame; for
# peers facing opposite directions, MetroMovement's encounter scan has already
# bridged this via physical-lane mapping, but lean is local to each pawn so
# we compare their target_lane in our frame using the centerline of the rail.
# Approximation: treat both pawns' lane indices in the querier's frame; for
# REVERSE peers vs FORWARD querier this is wrong, but the runner sets are
# typically same-direction in dense traffic. Good-enough for the jam.
func _lane_safety_score(candidate_lane: int) -> float:
	var clearance: float = pawn._metro_movement.get_lane_clearance(
		pawn, candidate_lane, encounter_lookahead
	)
	if lean_threat_weight <= 0.0:
		return clearance
	var threat: float = 0.0
	var nearby: Array[Pawn] = pawn._metro_movement.get_runners_near(
		pawn, encounter_lookahead
	)
	for peer: Pawn in nearby:
		var peer_target: int = peer.get_current_lane() + peer.lean_direction
		if peer_target == candidate_lane:
			threat += lean_threat_weight
	return clearance - threat


# --- Brain virtuals -------------------------------------------------------

func get_destination() -> Node3D:
	return destination


func get_move_speed() -> float:
	# Stalled behind a busy peer? Hold position. Auto-clear when peer frees.
	if _waiting_for != null:
		if not is_instance_valid(_waiting_for) or not _waiting_for.is_runner_paused():
			_waiting_for = null
		else:
			return 0.0
	if _actual_move_speed <= 0.0:
		_roll_speed()
	return _modulate_for_same_direction_peer(_actual_move_speed)


# Cap speed at the same-direction peer ahead so we never close to collision
# distance — knockback should only happen head-on. Returns `raw` if no peer
# in the lane, no MetroMovement back-ref, or the peer is opposing direction
# (those go through the shuffle protocol).
func _modulate_for_same_direction_peer(raw: float) -> float:
	if pawn._metro_movement == null:
		return raw
	var peer: Pawn = pawn._metro_movement.find_lane_occupant_ahead(
		pawn, pawn.get_current_lane(), encounter_lookahead
	)
	if peer == null:
		return raw
	if peer.is_routing_to_finish_point() != pawn.is_routing_to_finish_point():
		return raw
	# Same direction: match peer speed so the gap holds steady at lookahead.
	return minf(raw, peer.get_rail_speed())


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


# Pick the most-clear lane other than `current`, gated by min_clearance. Falls
# back to `current` if no candidate clears the floor (the AI holds rather than
# swerve into a tighter slot). Requires the Pawn's MetroMovement back-ref to
# be wired (set during runner registration); returns `current` if not.
func _pick_clear_lane(current: int) -> int:
	if Pawn.LANE_COUNT <= 1:
		return current
	if pawn._metro_movement == null:
		return current
	var ranked: Array[int] = pawn._metro_movement.rank_lanes_by_clearance(
		pawn, current, encounter_lookahead
	)
	if ranked.is_empty():
		return current
	var best: int = ranked[0]
	var clearance: float = pawn._metro_movement.get_lane_clearance(
		pawn, best, encounter_lookahead
	)
	if clearance < min_clearance:
		return current
	return best


func _next_random_lane_delay() -> float:
	var lo: float = minf(random_lane_interval_min, random_lane_interval_max)
	var hi: float = maxf(random_lane_interval_min, random_lane_interval_max)
	if hi <= 0.0:
		return 1.0
	return lo + randf() * maxf(hi - lo, 0.0)
