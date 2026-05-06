class_name AIBrain
extends Brain

# AI brain. Owns all rail-movement intent for an NPC: destination, speed, lane
# avoidance, run-up + shuffle telegraphs, obstacle dodge, ambient lane wander.
# MetroMovement queries these via the Brain virtual interface on Pawn. Timer-
# driven decisions tick through `physics_tick` using msec timestamps — avoids
# spawning Timer child nodes and keeps all decision state in one place.
#
# All tunables live on the assigned `AIBrainConfig` Resource. Different .tres
# files = different archetypes — see Scenes/Characters/Brains/Configs/.
# Per-pawn runtime state stays on this Node (every NPC gets its own AIBrain
# instance via the Brain child node).
#
# RunUpState (Stage 4 of the state-management refactor) replaces the four
# free-floating pre-shuffle fields with an explicit FSM:
#
#   IDLE        — no opposing peer in scope. Stance 0, no reroll.
#   TRACKING    — opposing peer detected, run-up window active. The reroll
#                 loop ticks (gated by stubbornness), broadcasting a stance
#                 lean toward the planned dodge side. No lane commit during
#                 RUNNING — pre-shuffle stance is pure telegraph.
#   COMMITTING  — shuffle has begun (locomotion == SHUFFLING). Stance now
#                 routes to `pawn.set_shuffle_telegraph` for the resolver
#                 collision math. Reroll loop continues.
#
# Transitions:
#   IDLE       ──_enter_tracking(other)─────►  TRACKING
#   TRACKING   ──_exit_runup()──────────────►  IDLE  (staleness or same-direction)
#   TRACKING   ──_advance_to_committing()──►   COMMITTING  (on_shuffle_began)
#   IDLE       ──_advance_to_committing()──►   COMMITTING  (peer initiated inside our scan)
#   COMMITTING ──_exit_runup()──────────────►  IDLE  (on_shuffle_resolved)
#
# Per-peer cooldown is owned by Pawn's `shuffle_ignored` (set by the initiator
# on resolve), not by this FSM — the encounter scan already skips re-engaging
# the same peer until they drift past hysteresis.

## Per-archetype tunables. Authored as a .tres under
## Scenes/Characters/Brains/Configs/ — Greeter.tres (parks at finish),
## Commuter.tres (oncoming traffic), Aggressive.tres / Stubborn.tres for
## variant feel. Required; null-config falls back to AIBrainConfig.new()
## defaults with a push_error.
@export var config: AIBrainConfig

enum RunUpState { IDLE, TRACKING, COMMITTING }

var destination: Node3D
var _actual_move_speed: float = 0.0
var _next_random_lane_msec: int = 0
var _avoidance_until_msec: int = 0

# The AI's current planned stance. -1 = lean/dodge left, +1 = lean/dodge
# right, 0 = stand upright and claim the lane. Drives the body via
# `_set_stance`:
#   - RUNNING / TRACKING → pure lean broadcast. Peers reading `lean_direction`
#                          see the tell, but the body holds its lane — the
#                          shuffle trigger is "same occupied lane + opposing
#                          pawn", and we don't want pre-shuffle swerves to
#                          spend the engagement window mid-tween.
#   - SHUFFLING / COMMITTING → locked into pawn.set_shuffle_telegraph for the
#                              collision-resolution math at the deadline. The
#                              lane commit happens at shuffle resolution.
# Re-rolled by `_tick_tracking` / `_tick_committing` every reaction_period_ms,
# gated by `stubbornness` (random skip). lean(0) returns the torso to upright.
var _current_stance: int = 0

# RunUpState FSM bookkeeping. Set/cleared exclusively through the transition
# helpers (`_enter_tracking`, `_exit_runup`, `_advance_to_committing`) so the
# four-field cluster doesn't drift out of sync.
var _runup: int = RunUpState.IDLE
var _runup_other: Pawn = null         # peer we're tracking against (TRACKING / COMMITTING)
var _runup_last_msec: int = 0         # last encounter signal — staleness gate (TRACKING)
var _runup_reaction_msec: int = 0     # next reroll consideration (TRACKING + COMMITTING)

# Stale-tell horizon (ms): if the encounter scan hasn't refreshed
# `_runup_last_msec` within this window, the cached peer is assumed gone
# (left our lane / moved out of range) and we drop back to IDLE.
const RUNUP_STALE_MS: int = 100

# Buffer in rail-meters between the obstacle and where the dodge tween starts.
# Used to shrink the telegraph prefix when an obstacle is too close for the
# full lead time (Stubborn detects benches at 0.5 m and walks at 1.4 m/s —
# can't afford a 300 ms prefix or it'd walk into the bench before the dodge
# tween starts). The Pawn-side _commit_lane_change clamps to 0.
const OBSTACLE_TELEGRAPH_SAFETY_MARGIN: float = 0.1


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


# Single dispatch point: pick which RunUp tick runs (if any), then run the
# state-independent ones (overtake, random-lane wander). Overtake gates on
# RunUp state internally — suppressed during TRACKING / COMMITTING so the AI
# doesn't tween into a lane mid-shuffle and trip the engagement gate.
func physics_tick(_delta: float) -> void:
	match _runup:
		RunUpState.TRACKING:
			_tick_tracking()
		RunUpState.COMMITTING:
			_tick_committing()
	_tick_overtake()
	_tick_random_lane()


# --- RunUpState transitions -----------------------------------------------

# IDLE → TRACKING. Cache the peer, arm the reroll cadence so a stubborn first-
# sight skip doesn't get re-rolled on the very next physics frame, and roll a
# fresh stance unless the stubbornness gate fires. The reroll loop in
# `_tick_tracking` owns subsequent reconsiderations.
func _enter_tracking(other: Pawn) -> void:
	_runup = RunUpState.TRACKING
	_runup_other = other
	_runup_last_msec = Time.get_ticks_msec()
	_runup_reaction_msec = Time.get_ticks_msec() + config.reaction_period_ms
	if randf() >= config.stubbornness:
		_set_stance(_roll_stance(other))


# TRACKING / COMMITTING → IDLE. Drop the cached peer + stance; clear the run-
# up tell on the body. Pawn's own lean(0) reset on locomotion exits SHUFFLING
# /KNOCKED_DOWN to RUNNING covers the COMMITTING → IDLE-via-resolved path
# defensively, but we issue lean(0) here too so the staleness path (RUNNING-
# only) clears the body too.
func _exit_runup() -> void:
	_runup = RunUpState.IDLE
	_runup_other = null
	_runup_last_msec = 0
	_runup_reaction_msec = 0
	_current_stance = 0
	if pawn.locomotion == Pawn.LocomotionState.RUNNING:
		pawn.lean(0)


# TRACKING (or IDLE) → COMMITTING. Fired from `_on_shuffle_began`. If we never
# saw a run-up encounter for this peer (player initiated inside our scan
# radius before we caught them), roll fresh; otherwise lock in the cached
# stance. Reset the reroll cadence so the first commit-window reroll has the
# full reaction window.
func _advance_to_committing(other: Pawn) -> void:
	var fresh_peer: bool = _runup_other != other
	_runup = RunUpState.COMMITTING
	_runup_other = other
	_runup_reaction_msec = Time.get_ticks_msec() + config.reaction_period_ms
	if fresh_peer:
		_set_stance(_roll_stance(other))
	else:
		_set_stance(_current_stance)  # routes to set_shuffle_telegraph since locomotion is now SHUFFLING


# --- Per-state ticks ------------------------------------------------------

# TRACKING: staleness check + stance reroll.
# Staleness: encounter scan stopped firing for the cached peer (peer left our
# lane / moved out of range) → drop to IDLE.
# Reroll: every reaction_period_ms, consider re-rolling (gated by stubbornness).
func _tick_tracking() -> void:
	if Time.get_ticks_msec() - _runup_last_msec > RUNUP_STALE_MS:
		_exit_runup()
		return
	_maybe_reroll_stance(_runup_other)


# COMMITTING: stance reroll only. Staleness doesn't apply — locomotion is
# SHUFFLING, encounter scan paused, the deadline timer on the initiator
# decides when this ends.
func _tick_committing() -> void:
	# `pawn.get_shuffle_other()` is more authoritative than `_runup_other`
	# during COMMITTING (covers the rare callee path where a fresh peer
	# attached). Falls back to cached if shuffle isn't fully wired.
	var other: Pawn = pawn.get_shuffle_other()
	if other == null:
		other = _runup_other
	_maybe_reroll_stance(other)


# Periodic reroll consideration. Bumps `_runup_reaction_msec` whether we
# re-roll or stubbornly skip, so stubbornness biases the *content* of the
# tick (skip vs roll) without changing its frequency.
#
# Wall-clock timing: shuffle.deadline_msec is wall-clock too (not affected
# by Engine.time_scale = 0.2 bullet-time), so 50 ms here is 50 ms of peer
# perception even though physics ticks 5× slower during bullet-time.
func _maybe_reroll_stance(other: Pawn) -> void:
	if config.reaction_period_ms <= 0 or other == null:
		return
	if Time.get_ticks_msec() < _runup_reaction_msec:
		return
	_runup_reaction_msec = Time.get_ticks_msec() + config.reaction_period_ms
	if randf() < config.stubbornness:
		return
	var new_stance: int = _roll_stance(other)
	if new_stance == _current_stance:
		return
	_set_stance(new_stance)


# Random-lane wander, extracted from the old physics_tick body so the
# RunUpState dispatcher stays clean.
func _tick_random_lane() -> void:
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
# Skipped during TRACKING / COMMITTING: an overtake tween in flight when
# distance closes inside `inner_shuffle_radius` would put us mid-tween, and
# the engagement gate in `Pawn.start_shuffle` would refuse to engage. The
# shuffle takes priority; overtaking can resume after it resolves.
func _tick_overtake() -> void:
	if not config.overtake_when_throttled:
		return
	if pawn.locomotion != Pawn.LocomotionState.RUNNING:
		return
	if Time.get_ticks_msec() < _avoidance_until_msec:
		return
	if _runup != RunUpState.IDLE:
		return
	if Pawn.LANE_COUNT <= 1:
		return
	var lookahead: float = config.encounter_lookahead
	if lookahead <= 0.0:
		return
	var current: int = pawn.get_current_lane()
	var peer_ahead: Pawn = pawn.find_lane_occupant_ahead(current, lookahead)
	if peer_ahead == null:
		return
	if peer_ahead.is_routing_to_finish_point() != pawn.is_routing_to_finish_point():
		return
	var current_clearance: float = pawn.get_lane_clearance(current, lookahead)
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


# --- Pawn signal handlers -------------------------------------------------

func _on_encounter_detected(other: Pawn, distance: float) -> void:
	if other == null:
		return
	# Same-direction peer (player or NPC walking our way): no shuffle. Speed
	# modulation in get_move_speed caps us at their speed so we trail without
	# ever colliding. Knockback should only fire head-on. If we were tracking
	# this peer (now flipped direction somehow), drop the run-up state.
	if other.is_routing_to_finish_point() == pawn.is_routing_to_finish_point():
		_waiting_for = null
		if _runup_other == other:
			_exit_runup()
		return
	# Transiently busy opposing NPC (mid-shuffle): stop and wait. Resolves
	# in <0.5s; once they're shuffle-engageable again `get_move_speed`'s
	# auto-clear releases us and the next encounter tick hits the live branch.
	#
	# Other paused states (KNOCKED_DOWN ~2.5s, PARKED forever) do NOT halt —
	# we fall through to the stance-roll branch and swerve around the body.
	# `_roll_stance` suppresses stay_chance for paused peers so the AI commits
	# to ±1 instead of phasing through.
	if other.is_in_group("npc") and other.locomotion == Pawn.LocomotionState.SHUFFLING:
		_wait_for(other)
		return
	_waiting_for = null

	# Live opposing peer. Refresh staleness timestamp regardless of state so
	# `_tick_tracking` sees we're still in scope.
	_runup_last_msec = Time.get_ticks_msec()

	# Enter TRACKING on first sight of a new peer. Stubbornness gate happens
	# inside `_enter_tracking` — at high stubbornness the AI may skip the
	# first-sight stance roll and hold lane (stance 0); the reroll loop
	# reconsiders every reaction_period_ms.
	if _runup == RunUpState.IDLE or _runup_other != other:
		_enter_tracking(other)

	# Outside the engagement zone: keep telegraphing; don't initiate yet.
	# Gives both pawns a real run-up window to read each other's tells.
	if distance > config.inner_shuffle_radius:
		return

	# Inside the engagement zone: AI-vs-AI engages the shuffle protocol.
	# Player initiates from PlayerBrain — we just keep telegraphing and wait.
	# `start_shuffle` no-ops if either side is mid-tween; the encounter scan
	# re-fires next frame and engages once both pawns settle. Run-up stance
	# is pure lean broadcast (see `_set_stance`), so the AI is always
	# lane-settled here unless an unrelated obstacle dodge / overtake /
	# random-lane is in flight.
	if other.is_in_group("npc"):
		pawn.start_shuffle(other, distance)


# Environment obstacle in the current lane — swerve via the clearance ranker
# instead of trusting the signal's pre-shuffled candidates. The signal still
# carries them as an obstacle-only filter, but registry-aware ranking also
# considers other pawns and applies the min_clearance floor.
#
# Close obstacles can't afford the default telegraph prefix (Stubborn detects
# benches at 0.5 m, walks at 1.4 m/s — 300 ms standing still would consume
# 0.42 m before the dodge tween even starts). We pass the available distance
# budget to the Pawn-side `_commit_lane_change`, which shrinks the telegraph
# prefix to fit. INF on non-obstacle paths = "use the full default."
func _on_obstacle_detected(_blocker: Node, distance: float, in_lane: int, _candidate_lanes: Array[int]) -> void:
	if Time.get_ticks_msec() < _avoidance_until_msec:
		return
	var clear_lane: int = _pick_clear_lane(in_lane)
	if clear_lane != in_lane:
		var prefix_budget: float = maxf(distance - OBSTACLE_TELEGRAPH_SAFETY_MARGIN, 0.0)
		_request_adjacent_lane_change(clear_lane, prefix_budget)
		_avoidance_until_msec = Time.get_ticks_msec() + int(config.avoidance_cooldown * 1000.0)


func _on_shuffle_began(other: Pawn, _other_telegraph: int, _deadline_msec: int) -> void:
	if other == null:
		return
	# TRACKING / IDLE → COMMITTING. Either path locks the stance in via
	# `pawn.set_shuffle_telegraph` (locomotion is now SHUFFLING, so
	# `_set_stance` routes there).
	_advance_to_committing(other)


# AI-vs-AI no longer reactively opposes the peer's commit signal — both AIs
# roll independently in `_tick_committing` so the telegraph game decides
# the outcome. Player-vs-AI is handled by the same reroll loop. Kept as a
# no-op override so the base-class signal connection stays wired.
func _on_shuffle_telegraph_changed(_direction: int) -> void:
	pass


# COMMITTING → IDLE on resolve (success or fail). Pawn already emits lean(0)
# on the locomotion transition out of SHUFFLING, so the body untells itself
# even before `_exit_runup` runs.
func _on_shuffle_resolved(_succeeded: bool, _direction: int) -> void:
	_exit_runup()


# --- Stance roll ----------------------------------------------------------

# Roll a fresh stance (-1 / 0 / +1) against the opposing peer. Weighted pick:
#   - Both adjacents blocked or out of bounds → forced 0 (must claim).
#   - Otherwise, weights = {0: stay_weight, -1: 1.0 if left clear,
#                            +1: 1.0 if right clear}.
#   - `stay_weight` = 0 when `other` is paused (knocked-down, parked, etc.).
#     A non-RUNNING peer is geometry — they won't move out of our way, so the
#     telegraph game collapses: stance MUST commit to a side or the AI walks
#     through the body. RUNNING peer = `stay_weight` = config.stay_chance.
#   - Peer-tell bias: if the peer is broadcasting a non-zero lean, the
#     anti-collision world-side gets a 2× weight boost — but stay still
#     remains a real option (unlike the old hard-oppose loop).
# The roll is non-deterministic by design — combined with stubbornness in
# the reroll loop, the telegraph game decides who wins each encounter.
func _roll_stance(other: Pawn) -> int:
	var current: int = pawn.get_current_lane()
	var left_clear: bool = current > 0 and _is_dodge_lane_clear(current - 1)
	var right_clear: bool = current < Pawn.LANE_COUNT - 1 and _is_dodge_lane_clear(current + 1)
	if not left_clear and not right_clear:
		return 0
	var stay_weight: float = config.stay_chance
	if other != null and not other.is_running():
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


# Apply a new stance value. Two side effects:
#   1. Cache `_current_stance` for the reroll loop and shuffle commit.
#   2. Broadcast as body lean — peers reading `lean_direction` see the tell
#      instantly; lean(0) returns the torso to upright posture. During
#      RUNNING this is the *only* effect — pre-shuffle stance is pure
#      telegraph, no lane commit. The shuffle trigger is "same physical
#      lane + opposing pawn", so a run-up swerve would just spend the
#      engagement window mid-tween and the engagement gate in
#      `start_shuffle` would refuse to engage. The lane commit happens at
#      shuffle resolution via the SHUFFLING branch below.
#   3. SHUFFLING → lock the shuffle telegraph to the stance. The Pawn's
#      shuffle resolver lane-changes by this direction at the deadline.
func _set_stance(value: int) -> void:
	var clamped: int = clampi(value, -1, 1)
	_current_stance = clamped
	pawn.lean(clamped)
	if pawn.locomotion == Pawn.LocomotionState.SHUFFLING:
		pawn.set_shuffle_telegraph(clamped)


# Picker-side lane changes (overtake, obstacle dodge, random-lane wander) score
# every lane and may pick a target two lanes away from current. Forwarding that
# straight to `pawn.request_lane_change` makes the body sweep across both lanes
# in one 0.30s tween — visually a "double lane jump" with no detent at the
# middle lane. Routing through this helper clamps the *step* to ±1 without
# discarding the picker's judgment: the next picker tick re-evaluates from the
# new lane and steps again if the goal lane is still further. The stance
# system (`_set_stance`) is pure lean broadcast and never reaches this helper.
#
# `max_prefix_meters` is the rail-distance the pawn can afford to advance
# during the telegraph prefix before the dodge tween must start. INF
# (default) tells the Pawn-side telegraph to use its full configured prefix;
# obstacle dodge passes the actual gap so close benches shrink the prefix
# to fit.
func _request_adjacent_lane_change(target_lane: int, max_prefix_meters: float = INF) -> void:
	var current: int = pawn.get_current_lane()
	var step: int = clampi(target_lane - current, -1, 1)
	if step == 0:
		return
	# Same Pawn API as the player path. If a prior lane change is still
	# tweening, the request queues instead of preempting. Pawn-side
	# `_commit_lane_change` owns the telegraph prefix — every lane change
	# starts with a held lean before the lateral motion begins, regardless
	# of caller.
	pawn.request_lane_change(current + step, max_prefix_meters)


# Lane is "clear enough" for an AI dodge if its clearance meets min_clearance.
# get_lane_clearance returns 0.0 if an obstacle is in the lane, otherwise the
# rail-distance to the nearest occupant (capped at lookahead). No registry =
# assume clear (defensive — keeps unit-test scenarios from soft-locking).
func _is_dodge_lane_clear(lane: int) -> bool:
	# Pre-registration → INF (defensive); inside config.min_clearance threshold
	# the lane reads as clear. Keeps unit-test scenarios from soft-locking.
	var clearance: float = pawn.get_lane_clearance(lane, config.encounter_lookahead)
	return clearance >= config.min_clearance


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
	var clearance: float = pawn.get_lane_clearance(candidate_lane, config.encounter_lookahead)
	if config.lean_threat_weight <= 0.0:
		return clearance
	var threat: float = 0.0
	var nearby: Array[Pawn] = pawn.get_runners_near(config.encounter_lookahead)
	for peer: Pawn in nearby:
		var peer_target: int = peer.get_current_lane() + peer.lean_direction
		if peer_target == candidate_lane:
			threat += config.lean_threat_weight
	return clearance - threat


# --- Brain virtuals -------------------------------------------------------

func get_destination() -> Node3D:
	return destination


func get_move_speed() -> float:
	if _actual_move_speed <= 0.0:
		_roll_speed()
	# modulate_for_wait short-circuits to 0 while halting behind a busy peer;
	# auto-clears in the modulator when the peer becomes lane-settled.
	# modulate_for_same_direction_peer caps at peer speed for convoy trailing.
	return modulate_for_wait(modulate_for_same_direction_peer(_actual_move_speed))


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
	if not pawn.is_registered():
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
