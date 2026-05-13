class_name Brain
extends Node

# Base class for Pawn brains. Brains are Nodes parented to their owning Pawn —
# one Brain instance per Pawn instance, so per-pawn state and signal
# connections never bleed across actors. Each Pawn finds its Brain by
# iterating children in _ready.
#
# (Earlier this type was a Resource, which Godot shares by reference: 6 NPCs
# pointed at the same AIBrain.tres, every bind() clobbered the prior pawn
# field, and _actual_move_speed / timers were shared across actors. Switching
# to Node fixes that with no extra per-instance bookkeeping.)
#
# Lifecycle:
#   1. Pawn._ready locates its Brain child and calls brain.bind(self). Brain
#      stores the pawn reference, wires up to the pawn's signal protocol, and
#      runs _on_bound().
#   2. Pawn forwards input to brain via process_input(event) on every _input.
#   3. Pawn forwards physics ticks to brain via physics_tick(delta) on every
#      _physics_process — for time-based decisions that don't fit signals
#      (e.g., AI random lane-change timers, cooldowns).
#
# Subclasses (PlayerBrain, AIBrain) override the handlers they care about and
# call the Pawn's intent methods (request_lane_change / start_shuffle /
# set_shuffle_telegraph / lean) to drive the body.

# What MetroMovement should do when a runner reaches the end of the rail.
# GOAL    — finish the run (used by the player).
# PARK    — stop at the finish marker (forward NPCs greeting the player).
# RESPAWN — wrap to the start of the rail with a stagger (oncoming NPCs).
enum EndOfRailAction { GOAL, PARK, RESPAWN }


var pawn: Pawn

# Pawn we're stalled behind because they're transiently busy (mid-shuffle,
# knocked down, mid-tween). While non-null, modulate_for_wait clamps
# get_move_speed() to 0 so this Pawn visibly halts. Auto-clears in the
# modulator the moment the peer is lane-settled — the encounter scan keeps
# firing each frame so the brain's next tick re-attempts engagement.
#
# PlayerBrain and AIBrain both used to carry this field locally with identical
# logic. Lifted here in Stage 2 of the state-management refactor.
var _waiting_for: Pawn


# Bind to a Pawn. Connects signal handlers and runs the subclass _on_bound hook.
func bind(p: Pawn) -> void:
	pawn = p
	if pawn == null:
		push_error("Brain.bind called with null Pawn.")
		return
	pawn.lane_change_started.connect(_on_lane_change_started)
	pawn.lane_change_completed.connect(_on_lane_change_completed)
	pawn.lane_change_canceled.connect(_on_lane_change_canceled)
	pawn.encounter_detected.connect(_on_encounter_detected)
	pawn.runner_passed.connect(_on_runner_passed)
	pawn.shuffle_began.connect(_on_shuffle_began)
	pawn.shuffle_telegraph_changed.connect(_on_shuffle_telegraph_changed)
	pawn.shuffle_resolved.connect(_on_shuffle_resolved)
	pawn.knocked_down.connect(_on_knocked_down)
	pawn.recovery_started.connect(_on_recovery_started)
	pawn.recovered.connect(_on_recovered)
	pawn.obstacle_detected.connect(_on_obstacle_detected)
	pawn.goal_reached.connect(_on_goal_reached)
	_on_bound()


# Default no-op handlers. Subclasses override what they care about.

func _on_bound() -> void:
	pass


# Called by Pawn._input for every input event. Default no-op; PlayerBrain
# overrides to read keyboard.
func process_input(_event: InputEvent) -> void:
	pass


# Called by Pawn._physics_process every frame. Default no-op; AIBrain overrides
# for timer-driven decisions.
func physics_tick(_delta: float) -> void:
	pass


func _on_lane_change_started(_from: int, _to: int) -> void:
	pass


func _on_lane_change_completed(_lane: int) -> void:
	pass


func _on_lane_change_canceled() -> void:
	pass


func _on_encounter_detected(_other: Pawn, _distance: float) -> void:
	pass


# Override in PlayerBrain to handle near-miss boost; NPCs no-op.
func _on_runner_passed(_other: Pawn) -> void:
	pass


func _on_shuffle_began(_other: Pawn, _other_telegraph: int, _deadline_msec: int) -> void:
	pass


func _on_shuffle_telegraph_changed(_direction: int) -> void:
	pass


func _on_shuffle_resolved(_succeeded: bool, _direction: int) -> void:
	pass


func _on_knocked_down() -> void:
	pass


func _on_recovery_started() -> void:
	pass


func _on_recovered() -> void:
	pass


func _on_obstacle_detected(_blocker: Node, _distance: float, _in_lane: int) -> void:
	pass


func _on_goal_reached() -> void:
	pass


# --- Locomotion-transition hooks (player-specific concerns) ---------------
#
# Pawn calls these from `_set_locomotion` when the matching transitions
# happen. Default no-op — NPCs ignore them. PlayerBrain overrides to drive
# bullet-time, camera-mode flips, mouse capture, and slow_sound playback so
# Pawn stays role-agnostic.
#
#   on_shuffle_entered  — fires when locomotion enters SHUFFLING (initiator
#                         AND callee paths — both go through _set_locomotion).
#   on_shuffle_exited   — fires when locomotion exits SHUFFLING to anything
#                         (RUNNING on success/end_subway_shuffle, KNOCKED_DOWN
#                         on fail). Pair with on_knocked_down for the failure
#                         case — both fire on SHUFFLING → KNOCKED_DOWN.
#   on_knocked_down     — fires when locomotion enters KNOCKED_DOWN.
#   on_recovered        — fires when locomotion transitions KNOCKED_DOWN →
#                         RUNNING (recovery completion). Does NOT fire for
#                         KNOCKED_DOWN → DISABLED (die during knockdown).

func on_shuffle_entered() -> void:
	pass


func on_shuffle_exited() -> void:
	pass


func on_knocked_down() -> void:
	pass


func on_recovered() -> void:
	pass


# --- Virtual interface: movement intent (queried by MetroMovement via Pawn) -

# The node this pawn is walking toward. AIBrain returns the authored export;
# PlayerBrain returns null (player speed is owned by Pawn.run_speed).
func get_destination() -> Node3D:
	return null


# Movement speed in m/s. AIBrain returns jitter-rolled move_speed.
func get_move_speed() -> float:
	return 0.0


# Distance along the rail at which this pawn should spawn.
func get_spawn_distance() -> float:
	return 0.0


# Whether to swerve away from obstacles ahead.
func should_avoid_obstacles() -> bool:
	return false


# Lookahead distance (m) for obstacle sampling.
func get_obstacle_lookahead() -> float:
	return 0.0


# Lookahead distance (m) for runner-vs-runner encounter detection along the
# rail. MetroMovement scans for other runners ahead in this pawn's lane within
# this distance and emits encounter_detected. 0.0 disables.
func get_encounter_lookahead() -> float:
	return 0.0


# Tracking range for the pass scan. 0.0 disables tracking on this runner.
func get_pass_radius() -> float:
	return 0.0


# Qualifier distance — same-lane within this radius flips TRACKED → QUALIFIED.
func get_pass_qualify_radius() -> float:
	return 0.0


# What should happen when this pawn reaches the end of the rail. Default is
# RESPAWN (loop back to start) — fits oncoming NPCs. PlayerBrain returns GOAL;
# AIBrain returns PARK or RESPAWN based on its destination.
func get_end_of_rail_action() -> int:
	return EndOfRailAction.RESPAWN


# Comfort gap (rail-meters) behind a same-direction peer. Inside this distance
# this Pawn slows BELOW peer speed so the gap regrows — prevents stacking.
# Subclasses may override per-instance via export.
func get_min_peer_gap() -> float:
	return 1.0


# Rail-distance ahead a target lane must be clear of obstacles AND peers before
# this pawn will swerve into it. Single source of truth for `Pawn.can_enter_lane`.
# Subclasses override to return `config.swerve_safety_distance`. Default fallback
# matches the BrainConfig default so brain-less unit tests don't soft-lock.
func get_swerve_safety_distance() -> float:
	return 1.5


# Body feel-tunables. Live on the brain's config Resource (BrainConfig +
# subclasses); Pawn reads them through these virtuals so the Pawn↔Brain
# contract stays narrow and Pawn never touches `brain.config` directly.
# Subclasses (PlayerBrain, AIBrain) override to return their `config.<field>`.
func get_start_speed() -> float:
	return 0.0


func get_max_speed() -> float:
	return 0.0


func get_acceleration_time() -> float:
	return 0.0


func get_shuffle_recovery_time() -> float:
	return 0.0


func get_shuffle_get_up_time() -> float:
	return 0.0


func get_shuffle_knockback_distance() -> float:
	return 0.0


# Begin halting behind a transiently-busy peer. Resets run_speed to start_speed
# so post-wait acceleration ramps from a known floor. Subclasses call this from
# their encounter handlers when the target is mid-shuffle / not yet engageable.
func _wait_for(other: Pawn) -> void:
	_waiting_for = other
	if pawn != null:
		pawn.set_run_speed(get_start_speed())


# Auto-clearing wait gate. Returns 0 while `_waiting_for` is non-null and the
# peer isn't yet lane-settled; otherwise returns `raw`. Compose with
# `modulate_for_same_direction_peer` in `get_move_speed` overrides:
#   return modulate_for_wait(modulate_for_same_direction_peer(raw))
# A peer mid-tween isn't engageable yet, so we keep halting until their tween
# completes — `is_lane_settled` already requires RUNNING + IDLE tween.
func modulate_for_wait(raw: float) -> float:
	if _waiting_for == null:
		return raw
	if not is_instance_valid(_waiting_for) or _waiting_for.is_lane_settled():
		_waiting_for = null
		return raw
	return 0.0


# Cap `raw` speed so this Pawn doesn't catch up to a same-direction peer ahead
# in its lane, AND backs off (drops below peer speed) when inside the comfort
# gap so the gap can recover instead of compressing into a stack. Returns the
# raw speed unchanged if no peer is in the lane, the peer is opposing-direction
# (those go through the shuffle protocol), the brain has no encounter scan
# enabled, or the MetroMovement back-ref isn't wired.
func modulate_for_same_direction_peer(raw: float) -> float:
	if pawn == null:
		return raw
	var lookahead: float = get_encounter_lookahead()
	if lookahead <= 0.0:
		return raw
	var current_lane: int = pawn.get_current_lane()
	var peer: Pawn = pawn.find_lane_occupant_ahead(current_lane, lookahead)
	if peer == null:
		return raw
	if peer.is_routing_to_finish_point() != pawn.is_routing_to_finish_point():
		return raw
	var peer_speed: float = peer.get_rail_speed()
	var distance: float = pawn.get_lane_clearance(current_lane, lookahead)
	var min_gap: float = get_min_peer_gap()
	if distance >= min_gap:
		# Far enough: match peer speed, hold the gap steady.
		return minf(raw, peer_speed)
	# Inside comfort gap: linear scale below peer_speed so peer pulls away.
	# At distance == 0 → speed 0 (full stop, no overlap). At distance == min_gap
	# → speed == peer_speed (continuous boundary with the match-branch above).
	return peer_speed * clampf(distance / min_gap, 0.0, 1.0)
