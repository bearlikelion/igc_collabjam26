class_name Pawn
extends CharacterBody3D

# Unified actor for the metro auto-runner. Both player and NPC instances are
# Pawns; behavior diverges via a Brain Resource assigned to the brain export.
# MetroMovement writes global_position every physics frame from
# get_current_lane() / get_lane_position(); Pawn never calls move_and_slide().
#
# Pawn owns the BODY and its SENSES:
#   - Locomotion state (single LocomotionState enum — see below)
#   - Lane state (target lane + sqrt-eased tween position; substate of RUNNING)
#   - Knockdown / recovery lifecycle (KnockdownPhase sub-enum)
#   - Subway-shuffle resolver (initiator-side: deadline timer + world-side compare)
#   - Subway-shuffle participant state (callee-side: telegraph + side-step)
#   - Encounter sense (rail-coord scan in MetroMovement: emits encounter_detected)
#   - Camera (a "sense": mouse pitch input, headbob, lane-lean spring,
#     shuffle camera tilt, mode flip on knockdown — all owned by Pawn)
#   - Bullet-time on shuffle (player-flagged via apply_bullet_time)
#   - Visual animation playback (die, recover, walk, interact_*)
#   - Visual show/hide tied to camera mode
#
# Locomotion state machine (see LocomotionState below):
#   RUNNING  ──start_shuffle──────►   SHUFFLING
#   RUNNING  ──knock_down_from_*──►   KNOCKED_DOWN(DOWN)
#   RUNNING  ──set_movement_blocked►  BLOCKED
#   RUNNING  ──reach_goal─────────►   FINISHED
#   RUNNING  ──park_at_finish─────►   PARKED
#   any      ──die────────────────►   DISABLED
#   SHUFFLING ──_complete_shuffle─►   RUNNING (initiator success → lane change)
#   SHUFFLING ──end_subway_shuffle►   SIDESTEPPING (callee survived)
#   SHUFFLING ──_fail_shuffle─────►   KNOCKED_DOWN(DOWN)
#   SIDESTEPPING ──lerp complete──►   RUNNING
#   KNOCKED_DOWN(DOWN) ──recovery starts──►  KNOCKED_DOWN(RECOVERING)
#   KNOCKED_DOWN(RECOVERING) ──recover────►  RUNNING
#   BLOCKED ──set_movement_blocked(false)──► RUNNING
#
# All state writes go through _set_locomotion(new_state), which emits
# locomotion_changed(old, new) and is the single source of truth.
#
# Brain owns DECISIONS only:
#   - Translates Pawn signals into intent calls (request_lane_change,
#     start_shuffle, set_shuffle_telegraph, lean)
#   - PlayerBrain reads keyboard via process_input forwarded from Pawn;
#     AIBrain ticks msec timers via physics_tick forwarded from Pawn.
#
# Brain is a child Node (one per Pawn instance, no cross-actor state sharing).
# Pawn._ready locates the first Brain child and calls brain.bind(self), which
# stores the pawn ref and connects to Pawn's signal protocol. metro_1.tscn
# attaches a PlayerBrain or AIBrain script to each Pawn's Brain child node.

# Lane geometry — single source of truth, also read by MetroMovement.
const LANE_OFFSETS: Array[float] = [-1.0, 0.0, 1.0]
const LANE_COUNT: int = 3
const START_LANE: int = LANE_COUNT / 2

# Top-level locomotion state. Mutually exclusive — one of these at a time.
# Lane tween is a *substate* of RUNNING (tracked by _tween_active separately).
enum LocomotionState {
	RUNNING,        # default; lane tween allowed
	SHUFFLING,      # subway-shuffle window (initiator OR callee — see shuffle.is_initiator)
	SIDESTEPPING,   # callee post-shuffle lateral lerp
	KNOCKED_DOWN,   # see knockdown_phase
	BLOCKED,        # external pause (cutscene / waiting for goal trigger), throttled to start_speed
	PARKED,         # FORWARD NPCs at finish marker
	FINISHED,       # player reached goal
	DISABLED,       # die() — terminal, no input, no physics
}

# Substate of KNOCKED_DOWN. Only meaningful while locomotion == KNOCKED_DOWN.
enum KnockdownPhase { DOWN, RECOVERING }


# Shuffle bookkeeping. Lives only while locomotion == SHUFFLING; instantiated on
# entry (start_shuffle / begin_subway_shuffle), nulled on exit (resolve, knock
# down, stop). Initiator owns the deadline timer + resolver; callee just picks
# a telegraph and waits for the initiator to call back into it.
class Shuffle:
	var is_initiator: bool = false
	var other: Pawn
	var deadline_msec: int = 0
	var time_left: float = 0.0
	var my_telegraph: int = 0       # this Pawn's chosen side (-1, 0, +1)
	var their_telegraph: int = 0    # the other Pawn's last-seen telegraph
	var previous_time_scale: float = 1.0

# --- Signals: Pawn → Brain (results out) -----------------------------------

# Locomotion telemetry — what's happening to my body.
signal lane_change_started(from_lane: int, to_lane: int)
signal lane_change_completed(lane: int)
signal lane_change_canceled()
signal goal_reached()

# Encounter events.
signal encounter_detected(other: Pawn, distance: float)
signal shuffle_began(other: Pawn, other_telegraph: int, deadline_msec: int)
signal shuffle_telegraph_changed(direction: int)
signal shuffle_resolved(succeeded: bool, direction: int)
signal knocked_down()
signal recovery_started()
signal recovered()

# Planning events. Emitted by MetroMovement when its forward scan finds an
# `obstacle` group node in the runner's lane. Brain decides the response —
# PlayerBrain knocks the pawn down; AIBrain swerves to a candidate lane.
# `candidate_lanes` is the pre-filtered list of clear lanes (already
# shuffled), so AI brains can just pick the first.
signal obstacle_detected(blocker: Node, distance: float, in_lane: int, candidate_lanes: Array[int])

# Locomotion lifecycle. Fires whenever locomotion changes.
signal locomotion_changed(old_state: int, new_state: int)


# --- Exports ---------------------------------------------------------------

# The Brain that decides intent for this Pawn. Brains are child Nodes — each
# Pawn instance owns its own Brain (PlayerBrain on the player, AIBrain on
# NPCs). Pawn._ready locates the first Brain child and calls brain.bind(self).
# Resolved in _ready (not @onready) so editor-tool Pawns ignore it.
var brain: Brain

# Brain claims these at bind time via set_camera_active / set_bullet_time_owner.
# Off by default; PlayerBrain turns them on. Kept as plain fields (not exports)
# so the Pawn's authored surface stays role-agnostic.
var is_active_camera: bool = false
var apply_bullet_time: bool = false

@export_group("Run Speed")
@export var start_speed: float = 0.5
@export var max_speed: float = 3.0
## Time in seconds to accelerate from start_speed to max_speed.
@export var acceleration_time: float = 10.0

@export_group("Lane Change")
@export_range(0.05, 1.0, 0.01, "suffix:s") var lane_tween_duration: float = 0.30

@export_group("Subway Shuffle")
## Bullet-time window during which the initiating brain commits a side.
@export var shuffle_choice_time: float = 0.5
@export_range(0.05, 1.0, 0.01) var shuffle_time_scale: float = 0.2
## Side-step displacement when a callee survives a shuffle (lerp duration is
## shuffle_lane_move_time). Initiator does NOT side-step — it lane-changes.
@export var shuffle_lane_distance: float = 1.0
@export var shuffle_lane_move_time: float = 0.25
@export var shuffle_debug_enabled: bool = false

@export_group("Knockdown")
## Total knockdown lockout in seconds.
@export var shuffle_recovery_time: float = 2.5
## Get-up window inside the lockout — recover anim starts when remaining ≤ this.
@export var shuffle_get_up_time: float = 1.0
## Distance to push the pawn away from the impact origin on knockdown.
@export var shuffle_knockback_distance: float = 2.0

# Camera config (mouse / headbob / lane lean / shuffle tilt) lives on the
# PawnCamera rig — Pawn drives intent only.

@export_group("Visual")
@export var visual: CharacterVisual


# The camera rig — singleton, lives at level scene root in group "player_camera".
# PlayerBrain resolves it on bind and assigns it here. Stays null on NPCs.
# Every camera_rig usage in this file is null-guarded.
var camera_rig: PawnCamera

# MetroMovement back-reference, written during runner registration. Pawn uses
# it to forward set_shuffle_ignored into the rail-coord encounter scan. Null
# until registration completes; null-guarded at the call site.
var _metro_movement: MetroMovement


# --- State ----------------------------------------------------------------

var run_speed: float = 0.0

# Top-level locomotion state. Single source of truth — all transitions go
# through _set_locomotion(new_state). Default RUNNING.
var locomotion: int = LocomotionState.RUNNING
# Substate of KNOCKED_DOWN. Read only when locomotion == KNOCKED_DOWN.
var knockdown_phase: int = KnockdownPhase.DOWN

# Lane state. _tween_active is a substate of RUNNING (tween allowed concurrent
# with running, cancelled when entering SHUFFLING / KNOCKED_DOWN).
var _target_lane: int = START_LANE
var _lane_position: float = float(START_LANE)
var _tween_from: float = float(START_LANE)
var _tween_elapsed: float = 0.0
var _tween_active: bool = false

# Knockdown timing. _recovery_time_left ticks down inside KNOCKED_DOWN; the
# transition DOWN → RECOVERING fires when it reaches shuffle_get_up_time and
# the visual can begin the recover animation.
var _recovery_time_left: float = 0.0

# Active shuffle bookkeeping. Non-null iff locomotion == SHUFFLING.
var shuffle: Shuffle

# Side-step state (lateral lerp during SIDESTEPPING).
var _shuffle_lane_start_position: Vector3 = Vector3.ZERO
var _shuffle_lane_target_position: Vector3 = Vector3.ZERO
var _shuffle_lane_elapsed: float = 0.0

# Parking offset (applied by MetroMovement while locomotion == PARKED).
var _parked_offset: Vector3 = Vector3.ZERO

# Rail direction — set by MetroMovement at registration based on destination
# geometry. True = same direction as player (toward finish end of rail).
var _is_forward_runner: bool = true

# Camera state lives on the PawnCamera rig (rotation, headbob phase, lane-lean
# spring). Pawn passes intent via setters and per-frame snapshots in _process.


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	run_speed = start_speed
	# Find the Brain child node and bind. Each Pawn instance owns its own
	# Brain — PlayerBrain on the player, AIBrain on NPCs. Brain decides
	# whether this Pawn claims the camera and bullet-time during _on_bound.
	brain = _find_brain_child()
	if brain != null:
		brain.bind(self)


func _find_brain_child() -> Brain:
	for child: Node in get_children():
		if child is Brain:
			return child as Brain
	return null


# Brain hook: claim this Pawn's Camera3D as the active view, capture the
# mouse, and hide the visual (first-person). PlayerBrain calls this at bind.
func set_camera_active(active: bool) -> void:
	is_active_camera = active
	if not active or camera_rig == null:
		return
	camera_rig.set_active(true)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if visual != null:
		visual.hide()


# Brain hook: opt this Pawn in to bullet-time on shuffle. Player-only effect.
func set_bullet_time_owner(value: bool) -> void:
	apply_bullet_time = value


func _physics_process(delta: float) -> void:
	# DISABLED skips brain tick too — actor is dead, nothing should fire.
	if locomotion == LocomotionState.DISABLED:
		return
	match locomotion:
		LocomotionState.KNOCKED_DOWN:
			_tick_knockdown(delta)
		LocomotionState.SIDESTEPPING:
			_tick_sidestep(delta)
		LocomotionState.SHUFFLING:
			_tick_shuffle(delta)
		LocomotionState.RUNNING:
			_tick_running(delta)
		# BLOCKED / PARKED / FINISHED — no per-state physics work; brain still
		# ticks below in case it wants to react via timers.
	if brain != null:
		brain.physics_tick(delta)


# Per-state ticks. Each one is responsible for its own internal updates and
# any auto-transitions (e.g. SIDESTEPPING → RUNNING when the lerp completes).

func _tick_running(delta: float) -> void:
	_update_lane_tween(delta)
	_update_run_speed(delta)
	if visual != null:
		visual.set_move_speed(run_speed)


func _tick_shuffle(_delta: float) -> void:
	# Initiator-only: tick deadline, resolve when expired.
	if shuffle == null or not shuffle.is_initiator:
		return
	shuffle.time_left = max(0.0, float(shuffle.deadline_msec - Time.get_ticks_msec()) / 1000.0)
	if Time.get_ticks_msec() >= shuffle.deadline_msec:
		_resolve_subway_shuffle()


func _tick_sidestep(delta: float) -> void:
	_update_shuffle_lane_move(delta)


func _tick_knockdown(delta: float) -> void:
	_update_knockdown_recovery(delta)


func _process(_delta: float) -> void:
	if camera_rig == null:
		return
	# Per-frame intents the rig needs to render headbob + lane lean. Pawn passes
	# 0 speed when not RUNNING so headbob settles to neutral.
	var effective_speed: float = run_speed if locomotion == LocomotionState.RUNNING else 0.0
	camera_rig.set_speed(effective_speed)
	camera_rig.set_tween_snapshot(_tween_active, _tween_from, float(_target_lane), get_tween_progress())


# Camera mouse-look + mouse-mode toggle, then forward to brain. Mouse handling
# only runs when this Pawn has an active camera (player only).
func _input(event: InputEvent) -> void:
	if is_active_camera and camera_rig != null:
		if can_look() and event is InputEventMouseMotion:
			var motion: InputEventMouseMotion = event as InputEventMouseMotion
			camera_rig.apply_pitch_input(motion.relative.y)
		if event.is_action_pressed("ui_cancel"):
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
					else Input.MOUSE_MODE_CAPTURED
	if brain != null:
		brain.process_input(event)


# --- Public API: Brain → Pawn (intent in) ---------------------------------

# Brain commits to a discrete lane. Tweens via _commit_lane_change. Lane
# changes are only allowed while RUNNING (tween is a substate of RUNNING).
func request_lane_change(target_lane: int) -> void:
	if locomotion != LocomotionState.RUNNING:
		return
	_commit_lane_change(target_lane)


# Brain initiates a shuffle encounter. This Pawn becomes the initiator.
func start_shuffle(other: Pawn) -> void:
	if locomotion == LocomotionState.SHUFFLING or locomotion == LocomotionState.KNOCKED_DOWN or other == null:
		return
	shuffle = Shuffle.new()
	shuffle.is_initiator = true
	shuffle.other = other
	shuffle.deadline_msec = Time.get_ticks_msec() + int(shuffle_choice_time * 1000.0)
	shuffle.time_left = shuffle_choice_time
	_set_locomotion(LocomotionState.SHUFFLING)
	run_speed = 0.0
	# Complete (don't cancel) the in-flight tween so the player's pressed lane
	# intent is honored before shuffle math. Previously this rounded to the
	# nearest integer of `_lane_position`, which silently dropped the press
	# whenever the tween was less than half-way (e.g. 1 → 2 at pos 1.4 landed
	# back at 1). Shuffle direction (`_target_lane + direction` in
	# `_complete_subway_shuffle`) now operates from the intended lane.
	_snap_tween_to_target_if_active()
	if apply_bullet_time:
		shuffle.previous_time_scale = Engine.time_scale
		Engine.time_scale = shuffle_time_scale
	if camera_rig != null:
		camera_rig.engage_shuffle_tilt(0)
	shuffle.their_telegraph = other.begin_subway_shuffle(self, shuffle.deadline_msec)
	shuffle_began.emit(other, shuffle.their_telegraph, shuffle.deadline_msec)


# Brain commits a shuffle direction.
func set_shuffle_telegraph(direction: int) -> void:
	if locomotion != LocomotionState.SHUFFLING or shuffle == null:
		return
	var clamped: int = clampi(direction, -1, 1)
	if clamped == shuffle.my_telegraph:
		return
	shuffle.my_telegraph = clamped
	if camera_rig != null:
		camera_rig.engage_shuffle_tilt(clamped)
	if shuffle.other != null:
		shuffle.other.shuffle_telegraph_changed.emit(clamped)


# Brain announces a visible body lean — held lane intent. Routes to torso-lean
# animation and the camera rig's lane-lean spring. Harmless during shuffle:
# the rig suppresses lane lean while shuffle tilt is engaged, so this only
# updates the dormant target until shuffle ends.
func lean(direction: int) -> void:
	if camera_rig != null:
		camera_rig.set_lean_direction(direction)
	if visual == null:
		return
	if direction < 0:
		visual.play_interact_left()
	elif direction > 0:
		visual.play_interact_right()


# Mark a Pawn as ignored for the rail-coord encounter scan until it drifts
# past the hysteresis margin (see MetroMovement.ENCOUNTER_IGNORE_HYSTERESIS).
# Used by PlayerBrain on same-direction-collision instant-knockdown so the
# scan doesn't re-trigger the same encounter on recovery. Cleared by
# MetroMovement._maybe_clear_runner_ignore.
func set_shuffle_ignored(other: Pawn) -> void:
	if _metro_movement == null:
		return
	_metro_movement.set_runner_shuffle_ignored(self, other)


# --- Subway-shuffle participant hooks (called by initiator on callee) -----

func begin_subway_shuffle(from: Pawn, deadline_msec: int) -> int:
	shuffle = Shuffle.new()
	shuffle.is_initiator = false
	shuffle.other = from
	shuffle.deadline_msec = deadline_msec
	_set_locomotion(LocomotionState.SHUFFLING)
	# Same rationale as start_shuffle: complete any in-flight tween to honor
	# the callee's pressed intent before the shuffle freezes its motion.
	_snap_tween_to_target_if_active()
	if camera_rig != null:
		camera_rig.engage_shuffle_tilt(0)
	shuffle_began.emit(from, 0, deadline_msec)
	return shuffle.my_telegraph


func end_subway_shuffle() -> void:
	var direction: int = shuffle.my_telegraph if shuffle != null else 0
	shuffle = null
	if camera_rig != null:
		camera_rig.disengage_shuffle_tilt()
	if visual != null:
		visual.play_walk()
	# SIDESTEPPING transitions back to RUNNING when the lerp completes.
	# If the side-step setup bails (zero direction, zero distance, degenerate
	# basis), skip SIDESTEPPING and resume RUNNING immediately.
	if _start_shuffle_lane_move(direction):
		_set_locomotion(LocomotionState.SIDESTEPPING)
	else:
		_set_locomotion(LocomotionState.RUNNING)


func stop_subway_shuffle() -> void:
	shuffle = null
	if camera_rig != null:
		camera_rig.disengage_shuffle_tilt()
	_set_locomotion(LocomotionState.RUNNING)


# --- Public API: queries --------------------------------------------------

func get_current_lane() -> int:
	return _target_lane


# Teleport: snap to a lane bypassing all gates. For respawn / level setup only.
# Gameplay lane changes go through request_lane_change() so they tween.
func set_current_lane(lane: int) -> void:
	_target_lane = clampi(lane, 0, LANE_COUNT - 1)
	_lane_position = float(_target_lane)
	_tween_active = false


func get_lane_position() -> float:
	return _lane_position



# Current along-rail speed (m/s). MetroMovement queries this for every runner.
# Player → PlayerBrain returns pawn.run_speed (the start_speed→max_speed curve).
# NPC    → AIBrain returns its jittered _actual_move_speed.
func get_rail_speed() -> float:
	if brain == null:
		return 0.0
	return brain.get_move_speed()


func get_shuffle_telegraph() -> int:
	return shuffle.my_telegraph if shuffle != null else 0


# Anything other than RUNNING counts as paused — including PARKED, FINISHED,
# and BLOCKED. Pre-Stage-1 only checked SHUFFLING / KNOCKED_DOWN /
# SIDESTEPPING / DISABLED. The widening is safe: MetroMovement short-circuits
# PARKED and FINISHED via `runner.finished`; BLOCKED is unreached today.
# AIBrain treats the new states as paused, so oncoming NPCs swerve around
# parked greeters and finished players (was a latent bug before).
func is_runner_paused() -> bool:
	return locomotion != LocomotionState.RUNNING


func is_routing_to_finish_point() -> bool:
	return _is_forward_runner


func set_rail_forward(value: bool) -> void:
	_is_forward_runner = value


func is_shuffle_active() -> bool:
	return locomotion == LocomotionState.SHUFFLING


func should_avoid_obstacles() -> bool:
	if brain == null:
		return false
	return brain.should_avoid_obstacles()


func get_obstacle_lookahead() -> float:
	if brain == null:
		return 0.0
	return brain.get_obstacle_lookahead()


func get_encounter_lookahead() -> float:
	if brain == null:
		return 0.0
	return brain.get_encounter_lookahead()


func reach_goal() -> void:
	if locomotion == LocomotionState.FINISHED:
		return
	run_speed = 0.0
	_set_locomotion(LocomotionState.FINISHED)
	goal_reached.emit()


func is_goal_reached() -> bool:
	return locomotion == LocomotionState.FINISHED


# Block external locomotion (e.g. cutscene, pre-goal pause). On entry, run_speed
# is reset to start_speed so the post-unblock acceleration ramps from a known
# floor rather than wherever the player happened to be.
# NOTE: No call site enters BLOCKED in the current codebase — the state is
# wired for future use (intros, cutscenes). MetroMovement's defensive
# `set_movement_blocked(false)` calls are no-ops as a result.
func set_movement_blocked(blocked: bool) -> void:
	if blocked:
		if locomotion == LocomotionState.BLOCKED:
			return
		run_speed = start_speed
		_set_locomotion(LocomotionState.BLOCKED)
	else:
		if locomotion != LocomotionState.BLOCKED:
			return
		_set_locomotion(LocomotionState.RUNNING)


func is_movement_blocked() -> bool:
	return locomotion == LocomotionState.BLOCKED


# --- Parking (FORWARD pawns at end of rail) -------------------------------

func park_at_finish(offset: Vector3) -> void:
	_parked_offset = offset
	_set_locomotion(LocomotionState.PARKED)
	if visual != null:
		visual.pause_animation()


func is_parked_at_finish() -> bool:
	return locomotion == LocomotionState.PARKED


func get_parked_offset() -> Vector3:
	return _parked_offset


# --- Knockdown lifecycle ---------------------------------------------------

func knock_down_from_shuffle() -> void:
	if locomotion == LocomotionState.KNOCKED_DOWN:
		return
	# Clear any active shuffle bookkeeping — covers the callee path where
	# the initiator failed and called knock_down_from_shuffle on us before
	# the caller could null shuffle from this side.
	shuffle = null
	_recovery_time_left = maxf(shuffle_recovery_time, shuffle_get_up_time)
	knockdown_phase = KnockdownPhase.DOWN
	_set_locomotion(LocomotionState.KNOCKED_DOWN)
	# Hold the camera in shuffle-tilt mode with a zero-degree target so it
	# rolls back to upright as the player falls (lane lean is suppressed).
	if camera_rig != null:
		camera_rig.engage_shuffle_tilt(0)
	# Player flips to third-person and shows its body during knockdown.
	if is_active_camera and camera_rig != null:
		camera_rig.apply_mode(PawnCamera.Mode.THIRD_PERSON)
	if visual != null:
		visual.show()
		visual.play_die()
	knocked_down.emit()


# Push this Pawn back from the impact origin by shuffle_knockback_distance.
# NOTE: For rail-driven Pawns this mutation is overwritten the same frame —
# MetroMovement listens for the `knocked_down` signal and runs its own rewind
# via `_on_runner_knocked_down` → `_rewind_runner` (mutates `Runner.distance_along`
# backward) → `_apply_runner_position` (overwrites global_position with parametric
# position). Kept as a fallback for non-rail Pawns / future use.
func apply_knockback_from(origin: Vector3) -> void:
	var direction: Vector3 = global_position - origin
	direction.y = 0.0
	if direction.length_squared() <= 0.001:
		direction = global_transform.basis.z
		direction.y = 0.0
	if direction.length_squared() <= 0.001:
		direction = Vector3.BACK
	direction = direction.normalized()
	global_position += direction * shuffle_knockback_distance


func _update_knockdown_recovery(delta: float) -> void:
	if _recovery_time_left > 0.0:
		_recovery_time_left = maxf(0.0, _recovery_time_left - delta)
	# DOWN → RECOVERING: get-up window opened and visual is ready to play recover.
	if knockdown_phase == KnockdownPhase.DOWN \
			and _recovery_time_left <= shuffle_get_up_time \
			and _can_start_recover():
		knockdown_phase = KnockdownPhase.RECOVERING
		if visual != null:
			visual.play_recover()
		recovery_started.emit()
	# RECOVERING → RUNNING: lockout expired and recover anim has finished.
	if _recovery_time_left <= 0.0 \
			and knockdown_phase == KnockdownPhase.RECOVERING \
			and _can_finish_recovery():
		_finish_knockdown_recovery()


func _finish_knockdown_recovery() -> void:
	knockdown_phase = KnockdownPhase.DOWN
	if visual != null:
		visual.play_walk()
	run_speed = start_speed
	_set_locomotion(LocomotionState.RUNNING)
	# Hand rotation.z back to the lane-lean spring.
	if camera_rig != null:
		camera_rig.disengage_shuffle_tilt()
	# Player flips back to first-person and re-hides its body.
	if is_active_camera and camera_rig != null:
		camera_rig.apply_mode(PawnCamera.Mode.FIRST_PERSON)
		if visual != null:
			visual.hide()
	recovered.emit()


func is_knocked_down() -> bool:
	return locomotion == LocomotionState.KNOCKED_DOWN


func _can_start_recover() -> bool:
	return visual == null or visual.can_start_recover()


func _can_finish_recovery() -> bool:
	return visual == null or not visual.is_recovery_locked()


# --- Locomotion lifecycle -------------------------------------------------

# All locomotion transitions go through here. Emits locomotion_changed on
# actual change; no-op on same-state assignment.
func _set_locomotion(new_state: int) -> void:
	if new_state == locomotion:
		return
	var old_state: int = locomotion
	locomotion = new_state
	locomotion_changed.emit(old_state, new_state)


func can_move() -> bool:
	return locomotion == LocomotionState.RUNNING


func can_look() -> bool:
	return locomotion != LocomotionState.DISABLED


func die() -> void:
	_set_locomotion(LocomotionState.DISABLED)
	if visual != null:
		visual.show()
		visual.play_die()


# --- Tween state read accessors (for camera lane-lean spring) -------------

func is_tween_active() -> bool:
	return _tween_active


func get_tween_from() -> float:
	return _tween_from


func get_tween_progress() -> float:
	if not _tween_active or lane_tween_duration <= 0.0:
		return 0.0
	return clampf(_tween_elapsed / lane_tween_duration, 0.0, 1.0)


# --- Internal --------------------------------------------------------------

func _commit_lane_change(next_lane: int) -> void:
	var clamped_lane: int = clampi(next_lane, 0, LANE_COUNT - 1)
	if clamped_lane == _target_lane:
		return
	var from_lane: int = _target_lane
	_target_lane = clamped_lane
	_tween_from = _lane_position
	_tween_elapsed = 0.0
	_tween_active = true
	lane_change_started.emit(from_lane, clamped_lane)


func _update_lane_tween(delta: float) -> void:
	if not _tween_active:
		return
	_tween_elapsed += delta
	var raw: float = clampf(_tween_elapsed / maxf(lane_tween_duration, 0.001), 0.0, 1.0)
	var eased: float = sqrt(raw)
	_lane_position = lerp(_tween_from, float(_target_lane), eased)
	if raw >= 1.0:
		_lane_position = float(_target_lane)
		_tween_active = false
		lane_change_completed.emit(_target_lane)


# Force-complete an in-flight lane tween to its `_target_lane`. Used when a
# locomotion change (shuffle entry) needs the lane state to settle on an
# integer without losing the player's pressed target.
func _snap_tween_to_target_if_active() -> void:
	if not _tween_active:
		return
	_lane_position = float(_target_lane)
	_tween_active = false
	lane_change_completed.emit(_target_lane)


func _resolve_subway_shuffle() -> void:
	if shuffle == null:
		return
	if shuffle.other != null:
		shuffle.their_telegraph = shuffle.other.get_shuffle_telegraph()
	var collision: bool = _shuffle_choices_collide()
	var succeeded: bool = shuffle.my_telegraph != 0 and not collision
	if succeeded:
		_complete_subway_shuffle(shuffle.my_telegraph)
	else:
		_fail_subway_shuffle()


func _complete_subway_shuffle(direction: int) -> void:
	run_speed = start_speed
	if apply_bullet_time:
		Engine.time_scale = shuffle.previous_time_scale
	var other: Pawn = shuffle.other
	if other != null:
		other.end_subway_shuffle()
		set_shuffle_ignored(other)
	shuffle = null
	if camera_rig != null:
		camera_rig.disengage_shuffle_tilt()
	_set_locomotion(LocomotionState.RUNNING)
	_commit_lane_change(_target_lane + direction)
	if direction < 0 and visual != null:
		visual.play_interact_left()
	elif direction > 0 and visual != null:
		visual.play_interact_right()
	shuffle_resolved.emit(true, direction)


func _fail_subway_shuffle() -> void:
	run_speed = start_speed
	if apply_bullet_time:
		Engine.time_scale = shuffle.previous_time_scale
	var other: Pawn = shuffle.other
	if other != null:
		other.apply_knockback_from(global_position)
		other.knock_down_from_shuffle()
		set_shuffle_ignored(other)
	shuffle = null
	# camera_rig stays engaged in shuffle tilt — knock_down_from_shuffle below
	# re-engages it with target=0 so the camera rolls upright as we fall.
	knock_down_from_shuffle()  # transitions self → KNOCKED_DOWN
	shuffle_resolved.emit(false, 0)


func _shuffle_choices_collide() -> bool:
	if shuffle == null or shuffle.other == null \
			or shuffle.my_telegraph == 0 or shuffle.their_telegraph == 0:
		return shuffle != null and shuffle.my_telegraph == 0
	var my_side: Vector3 = global_transform.basis.x * float(shuffle.my_telegraph)
	var their_side: Vector3 = shuffle.other.global_transform.basis.x * float(shuffle.their_telegraph)
	my_side.y = 0.0
	their_side.y = 0.0
	if my_side.length_squared() <= 0.001 or their_side.length_squared() <= 0.001:
		return shuffle.my_telegraph != shuffle.their_telegraph
	var side_dot: float = my_side.normalized().dot(their_side.normalized())
	return side_dot > 0.0


# Only called from _tick_running, so the goal_reached / movement_blocked
# branches present in the pre-Stage-1 code are no longer reachable here —
# both are state transitions out of RUNNING and run_speed is set on entry.
func _update_run_speed(delta: float) -> void:
	if run_speed < max_speed and acceleration_time > 0.0:
		var rate: float = (max_speed - start_speed) / acceleration_time
		run_speed = min(max_speed, run_speed + rate * delta)


# --- Side-step ------------------------------------------------------------

# Sets up the lateral lerp. Returns false on degenerate input (zero direction,
# zero distance, or degenerate basis) so the caller can transition straight
# back to RUNNING instead of entering SIDESTEPPING.
func _start_shuffle_lane_move(direction: int) -> bool:
	if direction == 0:
		return false
	var lane_direction: Vector3 = global_transform.basis.x * float(direction)
	lane_direction.y = 0.0
	if lane_direction.length_squared() <= 0.001 or is_zero_approx(shuffle_lane_distance):
		return false
	_shuffle_lane_start_position = global_position
	_shuffle_lane_target_position = global_position + lane_direction.normalized() * shuffle_lane_distance
	_shuffle_lane_elapsed = 0.0
	return true


func _update_shuffle_lane_move(delta: float) -> void:
	var scaled_delta: float = delta / maxf(Engine.time_scale, 0.001)
	_shuffle_lane_elapsed += scaled_delta
	var duration: float = maxf(shuffle_lane_move_time, 0.001)
	var weight: float = clampf(_shuffle_lane_elapsed / duration, 0.0, 1.0)
	var next_position: Vector3 = _shuffle_lane_start_position.lerp(_shuffle_lane_target_position, weight)
	next_position.y = global_position.y
	global_position = next_position
	if weight >= 1.0:
		_set_locomotion(LocomotionState.RUNNING)


# Camera math (pitch input, headbob, lane lean, shuffle tilt) lives on the
# PawnCamera rig — Pawn drives intent only:
#   - _input forwards mouse motion via camera_rig.apply_pitch_input
#   - _process forwards effective speed + lane tween snapshot each frame
#   - lean() forwards held lane intent via set_lean_direction
#   - shuffle entry / telegraph change → engage_shuffle_tilt(direction)
#   - knockdown entry → engage_shuffle_tilt(0)   (rolls back to upright)
#   - shuffle resolved / sidestep / recovery → disengage_shuffle_tilt
