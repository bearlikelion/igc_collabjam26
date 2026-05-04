class_name AIBrain
extends Brain

# AI brain. Owns all rail-movement intent for an NPC: destination, speed, lane
# avoidance. MetroMovement queries these via the Brain virtual interface on Pawn.
# Timer-driven lane decisions tick through physics_tick using msec timestamps —
# avoids spawning Timer child nodes and keeps all decision state in one place.
#
# All tunables live on the assigned `AIBrainConfig` Resource. Different .tres
# files = different archetypes — see Scenes/Characters/Brains/Configs/.
# Per-pawn runtime state stays on this Node (every NPC gets its own AIBrain
# instance via the Brain child node).

## Per-archetype tunables. Authored as a .tres under
## Scenes/Characters/Brains/Configs/ — Greeter.tres (parks at finish),
## Commuter.tres (oncoming traffic), Aggressive.tres / Stubborn.tres for
## variant feel. Required; null-config falls back to AIBrainConfig.new()
## defaults with a push_error.
@export var config: AIBrainConfig

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

# The AI's current planned stance. -1 = lean/dodge left, +1 = lean/dodge
# right, 0 = stand upright and claim the lane. Drives the body via
# `_set_stance`:
#   - RUNNING + non-zero → request a lane change toward the stance (run-up
#     preempt around the opposing peer).
#   - RUNNING + zero     → no lane change; the AI holds its current lane.
#   - SHUFFLING          → locked into pawn.set_shuffle_telegraph for the
#                          collision-resolution math at the deadline.
# Re-rolled by `_tick_stance_reroll` every reaction_period_ms, gated by
# `stubbornness` (random skip). Peers reading `lean_direction` see the
# tell instantly; lean(0) returns the torso to upright posture.
var _current_stance: int = 0

# Tracks the opposing peer this AI is currently telegraphing against.
# Set on first encounter scan that hits an opposing pawn; cleared on
# shuffle resolve OR via staleness check (encounter signal stopped firing
# for PRE_SHUFFLE_STALE_MS → peer left the lane). Used by the reroll loop
# to know who to consult for the peer-tell bias.
var _pre_shuffle_other: Pawn = null
var _pre_shuffle_last_msec: int = 0
const PRE_SHUFFLE_STALE_MS: int = 100

# Wall-clock timestamp of the next stance reroll consideration. Bumped by
# reaction_period_ms each tick whether we re-roll or stubbornly skip, so
# stubbornness biases the *content* of the tick (skip vs roll) without
# changing its frequency.
var _next_reaction_msec: int = 0


# --- Brain hooks ----------------------------------------------------------

func _on_bound() -> void:
	if config == null:
		push_error("AIBrain on '%s' has no config — using AIBrainConfig.new() defaults." % pawn.name)
		config = AIBrainConfig.new()
	pawn.add_to_group("npc")
	destination = pawn.get_tree().get_first_node_in_group(config.destination_group)
	_roll_speed()
	if config.random_lane_changes:
		_next_random_lane_msec = Time.get_ticks_msec() + int(_next_random_lane_delay() * 1000.0)


func physics_tick(_delta: float) -> void:
	_tick_pre_shuffle_staleness()
	_tick_stance_reroll()
	_tick_overtake()
	if not config.random_lane_changes:
		return
	if Time.get_ticks_msec() < _next_random_lane_msec:
		return
	var clear_lane: int = _pick_clear_lane(pawn.get_current_lane())
	if clear_lane != pawn.get_current_lane():
		_request_adjacent_lane_change(clear_lane)
	_next_random_lane_msec = Time.get_ticks_msec() + int(_next_random_lane_delay() * 1000.0)


# Goal-seeking overtake: when a same-direction peer ahead is throttling our
# speed, switch to a faster lane. Trigger = `find_lane_occupant_ahead` finds
# a same-direction peer in our current lane within `encounter_lookahead`
# (mirrors `Brain.modulate_for_same_direction_peer`'s detection). Decision =
# pick the best alternative via `_lane_safety_score` and only commit when it
# beats current clearance by `overtake_clearance_margin` (so we don't bounce
# between equally congested lanes). Reuses `_avoidance_until_msec` so the
# obstacle dodge and the overtake share one cooldown — the AI can't ping-pong
# every frame.
#
# Skipped during run-up to an opposing peer (`_pre_shuffle_other != null`):
# the stance reroll already owns lane intent in that window, and overriding it
# here would yank the body away from the planned dodge side.
func _tick_overtake() -> void:
	if not config.overtake_when_throttled:
		return
	if pawn.locomotion != Pawn.LocomotionState.RUNNING:
		return
	if pawn._metro_movement == null:
		return
	if Time.get_ticks_msec() < _avoidance_until_msec:
		return
	if _pre_shuffle_other != null:
		return
	if Pawn.LANE_COUNT <= 1:
		return
	var lookahead: float = config.encounter_lookahead
	if lookahead <= 0.0:
		return
	var current: int = pawn.get_current_lane()
	var peer_ahead: Pawn = pawn._metro_movement.find_lane_occupant_ahead(pawn, current, lookahead)
	if peer_ahead == null:
		return
	if peer_ahead.is_routing_to_finish_point() != pawn.is_routing_to_finish_point():
		return
	var current_clearance: float = pawn._metro_movement.get_lane_clearance(pawn, current, lookahead)
	var best_lane: int = current
	var best_score: float = current_clearance
	for lane: int in range(Pawn.LANE_COUNT):
		if lane == current:
			continue
		var score: float = _lane_safety_score(lane)
		if score < config.min_clearance:
			continue
		if score > best_score:
			best_score = score
			best_lane = lane
	if best_lane == current:
		return
	if best_score - current_clearance < config.overtake_clearance_margin:
		return
	_request_adjacent_lane_change(best_lane)
	_avoidance_until_msec = Time.get_ticks_msec() + int(config.avoidance_cooldown * 1000.0)


func _on_encounter_detected(other: Pawn, distance: float) -> void:
	if other == null:
		return
	# Same-direction peer (player or NPC walking our way): no shuffle. Speed
	# modulation in get_move_speed caps us at their speed so we trail without
	# ever colliding. Knockback should only fire head-on.
	if other.is_routing_to_finish_point() == pawn.is_routing_to_finish_point():
		_waiting_for = null
		_clear_pre_shuffle_tell()
		return
	# Transiently busy opposing NPC (currently in another shuffle, will resolve
	# in <0.5s): stop and wait. get_move_speed zeros out until the peer is
	# RUNNING again. Encounter scan keeps firing, so once the peer frees up the
	# next call hits the active branch.
	#
	# Other paused states (KNOCKED_DOWN ~2.5s, PARKED forever) do NOT halt — we
	# fall through to the stance-roll branch and swerve around the body.
	# `_roll_stance` suppresses stay_chance for paused peers so the AI commits
	# to ±1 instead of phasing through.
	if other.is_in_group("npc") and other.locomotion == Pawn.LocomotionState.SHUFFLING:
		_waiting_for = other
		pawn.run_speed = config.start_speed
		return
	_waiting_for = null

	# First-encounter stance roll. The reroll loop in _tick_stance_reroll
	# owns subsequent reconsiderations (gated by stubbornness), so we only
	# roll fresh here when the opposing peer changes. _set_stance handles
	# all three side effects: lean broadcast, run-up preempt, and shuffle
	# telegraph (whichever applies given current locomotion).
	if _pre_shuffle_other != other:
		_pre_shuffle_other = other
		_set_stance(_roll_stance(other))
	_pre_shuffle_last_msec = Time.get_ticks_msec()

	# Outside the inner radius: keep telegraphing; don't initiate shuffle yet.
	# Gives both pawns a real run-up window to read each other's tells.
	if distance > config.inner_shuffle_radius:
		return

	# Inside the inner radius: AI-vs-AI engages the shuffle protocol. Player
	# initiates from PlayerBrain — we just keep telegraphing and wait for
	# them to start the shuffle. Paused peers (knocked-down player, busy NPC
	# handled above) — telegraph + preempt is the only response, no shuffle.
	if other.is_in_group("npc") and not other.is_runner_paused():
		if Time.get_ticks_msec() < _avoidance_until_msec:
			return
		pawn.start_shuffle(other)


# Environment obstacle in the current lane — swerve via the clearance ranker
# instead of trusting the signal's pre-shuffled candidates. The signal still
# carries them as an obstacle-only filter, but registry-aware ranking also
# considers other pawns and applies the min_clearance floor.
func _on_obstacle_detected(_blocker: Node, _distance: float, in_lane: int, _candidate_lanes: Array[int]) -> void:
	if Time.get_ticks_msec() < _avoidance_until_msec:
		return
	var clear_lane: int = _pick_clear_lane(in_lane)
	if clear_lane != in_lane:
		_request_adjacent_lane_change(clear_lane)
		_avoidance_until_msec = Time.get_ticks_msec() + int(config.avoidance_cooldown * 1000.0)


func _on_shuffle_began(other: Pawn, _other_telegraph: int, _deadline_msec: int) -> void:
	if other == null:
		return
	# Schedule the first stance re-roll. Continuous loop runs in physics_tick:
	# every reaction_period_ms wall-clock the AI considers reconsidering its
	# stance (stubbornness gates the actual re-roll). Same loop for player
	# and AI peers — that's what makes telegraphs feel responsive without
	# being deterministic about who wins.
	_next_reaction_msec = Time.get_ticks_msec() + config.reaction_period_ms
	# Lock the cached run-up stance into the shuffle telegraph. If we never
	# saw a run-up encounter for this peer (e.g. player initiated the shuffle
	# inside our scan radius before our scan caught them), roll fresh now.
	# Either way, _set_stance routes to set_shuffle_telegraph since locomotion
	# is already SHUFFLING by the time this signal fires.
	if _pre_shuffle_other != other:
		_pre_shuffle_other = other
		_set_stance(_roll_stance(other))
	else:
		_set_stance(_current_stance)


# AI-vs-AI no longer reactively opposes the peer's commit signal — both AIs
# roll independently in `_tick_stance_reroll` so the telegraph game decides
# the outcome. Player-vs-AI is handled by the same reroll loop. Kept as a
# no-op override so the base-class signal connection stays wired.
func _on_shuffle_telegraph_changed(_direction: int) -> void:
	pass


# Clear stance state on resolve (success or fail). Pawn already emits lean(0)
# on the locomotion transition out of SHUFFLING, so the body untells itself;
# we just drop the cached peer + stance so the next encounter rolls fresh.
func _on_shuffle_resolved(_succeeded: bool, _direction: int) -> void:
	_pre_shuffle_other = null
	_current_stance = 0
	_pre_shuffle_last_msec = 0
	_next_reaction_msec = 0


# --- Stance roll + reroll loop --------------------------------------------

# Roll a fresh stance (-1 / 0 / +1) against the opposing peer. Weighted pick:
#   - Both adjacents blocked or out of bounds → forced 0 (must claim).
#   - Otherwise, weights = {0: stay_weight, -1: 1.0 if left clear,
#                            +1: 1.0 if right clear}.
#   - `stay_weight` = 0 when `other` is paused (knocked-down, parked, etc.).
#     A non-RUNNING peer is geometry — they won't move out of our way, so the
#     telegraph game collapses: stance MUST commit to a side or the AI walks
#     through the body. RUNNING peer = `stay_weight` = config.stay_chance
#     (the negotiable case).
#   - Peer-tell bias: if the peer is broadcasting a non-zero lean, the
#     anti-collision world-side gets a 2× weight boost — but stay still
#     remains a real option (unlike the old hard-oppose loop).
# The roll is non-deterministic by design — combined with stubbornness in
# `_tick_stance_reroll`, the telegraph game decides who wins each encounter.
func _roll_stance(other: Pawn) -> int:
	var current: int = pawn.get_current_lane()
	var left_clear: bool = current > 0 and _is_dodge_lane_clear(current - 1)
	var right_clear: bool = current < Pawn.LANE_COUNT - 1 and _is_dodge_lane_clear(current + 1)
	if not left_clear and not right_clear:
		return 0
	var stay_weight: float = config.stay_chance
	if other != null and other.is_runner_paused():
		stay_weight = 0.0
	var weights: Dictionary[int, float] = {0: stay_weight}
	if left_clear:
		weights[-1] = 1.0
	if right_clear:
		weights[1] = 1.0
	if other != null and other.lean_direction != 0:
		var safe_side: int = _opposite_world_side(other, other.lean_direction)
		if weights.has(safe_side):
			weights[safe_side] *= 2.0
	return _weighted_pick(weights)


# Weighted random pick over a {value: weight} map. Returns 0 on degenerate
# inputs (empty dict / all zero weights) so callers don't need a guard.
func _weighted_pick(weights: Dictionary[int, float]) -> int:
	var total: float = 0.0
	for w: float in weights.values():
		total += w
	if total <= 0.0:
		return 0
	var r: float = randf() * total
	var fallback: int = 0
	for k: int in weights.keys():
		fallback = k
		r -= weights[k]
		if r <= 0.0:
			return k
	return fallback


# Apply a new stance value. Three side effects:
#   1. Cache `_current_stance` for the reroll loop and shuffle commit.
#   2. Broadcast as body lean — peers reading `lean_direction` see the tell
#      instantly; lean(0) returns the torso to upright posture.
#   3. Drive the body based on locomotion:
#      - RUNNING + non-zero stance → request lane change toward the stance
#        (run-up preempt around the opposing peer).
#      - RUNNING + zero stance     → cancel any pending lane change so a
#        prior re-roll's queued swerve doesn't drift us sideways after we
#        decide to claim the current lane.
#      - SHUFFLING                 → lock the shuffle telegraph to the stance.
func _set_stance(value: int) -> void:
	var clamped: int = clampi(value, -1, 1)
	_current_stance = clamped
	pawn.lean(clamped)
	match pawn.locomotion:
		Pawn.LocomotionState.RUNNING:
			var current: int = pawn.get_current_lane()
			# stance 0 → request our own lane to clear a queued swerve from
			# a prior re-roll. Same call when target == current also no-ops
			# the lane tween logic itself. See Pawn.request_lane_change.
			var target: int = clampi(current + clamped, 0, Pawn.LANE_COUNT - 1)
			pawn.request_lane_change(target)
		Pawn.LocomotionState.SHUFFLING:
			pawn.set_shuffle_telegraph(clamped)


# Picker-side lane changes (overtake, obstacle dodge, random-lane wander) score
# every lane and may pick a target two lanes away from current. Forwarding that
# straight to `pawn.request_lane_change` makes the body sweep across both lanes
# in one 0.30s tween — visually a "double lane jump" with no detent at the
# middle lane. Routing through this helper clamps the *step* to ±1 without
# discarding the picker's judgment: the next picker tick re-evaluates from the
# new lane and steps again if the goal lane is still further. The stance system
# (`_set_stance`) already produces ±1 targets and bypasses this helper.
func _request_adjacent_lane_change(target_lane: int) -> void:
	var current: int = pawn.get_current_lane()
	var step: int = clampi(target_lane - current, -1, 1)
	if step == 0:
		return
	pawn.request_lane_change(current + step)


# Lane is "clear enough" for an AI dodge if its clearance meets min_clearance.
# get_lane_clearance returns 0.0 if an obstacle is in the lane, otherwise the
# rail-distance to the nearest occupant (capped at lookahead). No registry =
# assume clear (defensive — keeps unit-test scenarios from soft-locking).
func _is_dodge_lane_clear(lane: int) -> bool:
	if pawn._metro_movement == null:
		return true
	var clearance: float = pawn._metro_movement.get_lane_clearance(
		pawn, lane, config.encounter_lookahead
	)
	return clearance >= config.min_clearance


# Drop the run-up tell — peer changed (same-direction now), or encounter
# scan stopped firing (staleness). Reset stance to 0 so the body stands
# upright; no stance to broadcast.
func _clear_pre_shuffle_tell() -> void:
	if _pre_shuffle_other == null:
		return
	_pre_shuffle_other = null
	_current_stance = 0
	_pre_shuffle_last_msec = 0
	if pawn.locomotion == Pawn.LocomotionState.RUNNING:
		pawn.lean(0)


# Staleness clear: encounter scan stopped firing for the cached peer (peer
# left our lane / moved out of range), so the tell no longer reflects an
# imminent shuffle. Don't clear during SHUFFLING — `_on_shuffle_resolved`
# owns cleanup once the encounter resolves.
func _tick_pre_shuffle_staleness() -> void:
	if _pre_shuffle_other == null:
		return
	if pawn.locomotion == Pawn.LocomotionState.SHUFFLING:
		return
	if Time.get_ticks_msec() - _pre_shuffle_last_msec <= PRE_SHUFFLE_STALE_MS:
		return
	_clear_pre_shuffle_tell()


# Periodic stance reroll. Active during run-up (RUNNING + opposing peer
# tracked) and the shuffle window (SHUFFLING). Stubbornness gates whether
# we re-roll on each tick — when stubborn we hold the current stance so
# peers reading our tell can rely on it; otherwise we re-roll fresh and
# may flip stance, including back to 0 (stand upright).
#
# Wall-clock timing: shuffle.deadline_msec is wall-clock too (not affected
# by Engine.time_scale = 0.2 bullet-time), so 50 ms here is 50 ms of peer
# perception even though physics ticks 5× slower during bullet-time.
func _tick_stance_reroll() -> void:
	if config.reaction_period_ms <= 0:
		return
	var in_runup: bool = (
		pawn.locomotion == Pawn.LocomotionState.RUNNING
		and _pre_shuffle_other != null
	)
	var in_shuffle: bool = (
		pawn.locomotion == Pawn.LocomotionState.SHUFFLING
		and pawn.shuffle != null
	)
	if not (in_runup or in_shuffle):
		return
	if Time.get_ticks_msec() < _next_reaction_msec:
		return
	_next_reaction_msec = Time.get_ticks_msec() + config.reaction_period_ms
	# Stubbornness gate: random skip = keep current stance, no re-roll this tick.
	if randf() < config.stubbornness:
		return
	var other: Pawn = pawn.shuffle.other if in_shuffle else _pre_shuffle_other
	if other == null:
		return
	var new_stance: int = _roll_stance(other)
	if new_stance == _current_stance:
		return
	_set_stance(new_stance)


# Pick this AI's telegraph (-1 / +1) such that its world-space side points
# opposite to the other Pawn's chosen world-side. If the other hasn't
# committed yet (other_telegraph == 0), default to +1.
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
		pawn, candidate_lane, config.encounter_lookahead
	)
	if config.lean_threat_weight <= 0.0:
		return clearance
	var threat: float = 0.0
	var nearby: Array[Pawn] = pawn._metro_movement.get_runners_near(
		pawn, config.encounter_lookahead
	)
	for peer: Pawn in nearby:
		var peer_target: int = peer.get_current_lane() + peer.lean_direction
		if peer_target == candidate_lane:
			threat += config.lean_threat_weight
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
	return modulate_for_same_direction_peer(_actual_move_speed)


func get_min_peer_gap() -> float:
	return config.min_peer_gap


func get_spawn_distance() -> float:
	return config.spawn_distance


func should_avoid_obstacles() -> bool:
	return config.avoid_obstacles


func get_obstacle_lookahead() -> float:
	return config.obstacle_lookahead


func get_encounter_lookahead() -> float:
	return config.encounter_lookahead


# Forward NPCs (destination = "finish") park as greeters at the end of the
# rail. Reverse NPCs (destination = "player" or anything else) loop back to
# the start so a fresh oncoming runner appears.
func get_end_of_rail_action() -> int:
	if config.destination_group == &"finish":
		return EndOfRailAction.PARK
	return EndOfRailAction.RESPAWN


# Body feel-tunables — read from the shared BrainConfig fields.

func get_start_speed() -> float:
	return config.start_speed


func get_max_speed() -> float:
	return config.max_speed


func get_acceleration_time() -> float:
	return config.acceleration_time


func get_shuffle_recovery_time() -> float:
	return config.shuffle_recovery_time


func get_shuffle_get_up_time() -> float:
	return config.shuffle_get_up_time


func get_shuffle_knockback_distance() -> float:
	return config.shuffle_knockback_distance



# --- Helpers --------------------------------------------------------------

func _roll_speed() -> void:
	var jitter: float = (randf() * 2.0 - 1.0) * config.move_speed_variance
	_actual_move_speed = maxf(0.1, config.move_speed * (1.0 + jitter))


# Pick the safest lane other than `current`, gated by min_clearance. "Safest"
# = clearance minus lean-threat (peers currently committing into the candidate
# lane reduce its score, see `_lane_safety_score`). Falls back to `current` if
# no candidate clears the floor — the AI holds rather than swerve into a
# tighter / more-contested slot. Used by random-lane changes and obstacle
# dodges; the lean-threat biases two AIs away from racing into the same lane
# in the same physics frame. Requires the Pawn's MetroMovement back-ref to be
# wired (set during runner registration); returns `current` if not.
func _pick_clear_lane(current: int) -> int:
	if Pawn.LANE_COUNT <= 1:
		return current
	if pawn._metro_movement == null:
		return current
	var best: int = current
	var best_score: float = -INF
	for lane: int in range(Pawn.LANE_COUNT):
		if lane == current:
			continue
		var score: float = _lane_safety_score(lane)
		if score < config.min_clearance:
			continue
		if score > best_score:
			best_score = score
			best = lane
	return best


func _next_random_lane_delay() -> float:
	var lo: float = minf(config.random_lane_interval_min, config.random_lane_interval_max)
	var hi: float = maxf(config.random_lane_interval_min, config.random_lane_interval_max)
	if hi <= 0.0:
		return 1.0
	return lo + randf() * maxf(hi - lo, 0.0)
