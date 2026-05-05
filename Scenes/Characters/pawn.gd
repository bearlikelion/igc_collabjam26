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
#   SHUFFLING ──end_subway_shuffle►   RUNNING (callee survived → lane change)
#   SHUFFLING ──_fail_shuffle─────►   KNOCKED_DOWN(DOWN)
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
const START_LANE: int = int(LANE_COUNT / 2)

# Top-level locomotion state. Mutually exclusive — one of these at a time.
# Lane tween is a *substate* of RUNNING (tracked by _tween_active separately).
enum LocomotionState {
	RUNNING,        # default; lane tween allowed
	SHUFFLING,      # subway-shuffle window (initiator OR callee — see shuffle.is_initiator)
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
	# Engine.time_scale snapshot lives on Pawn (`_shuffle_previous_time_scale`)
	# rather than here so cleanup in `_set_locomotion`'s SHUFFLING-exit branch
	# isn't coupled to this struct's lifetime — resolve paths null `shuffle`
	# at varying points relative to the locomotion transition.

# --- Signals: Pawn → Brain (results out) -----------------------------------

# Locomotion telemetry — what's happening to my body.
signal lane_change_started(from_lane: int, to_lane: int)
signal lane_change_completed(lane: int)
signal lane_change_canceled()
signal goal_reached()

# Intent broadcast. Fires when this Pawn's directional lean changes (via
# `lean()`). Captures held lane intent during RUNNING and the committed
# shuffle telegraph during SHUFFLING — both go through `lean()`. Other Pawns'
# brains observe peers' intents through this signal (or via the queryable
# `lean_direction` field). Pair-wise shuffle telegraph still emits separately
# on `shuffle_telegraph_changed` for the in-shuffle peer.
signal lean_changed(direction: int)

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

@export_group("Lane Change")
@export_range(0.05, 1.0, 0.01, "suffix:s") var lane_tween_duration: float = 0.30

@export_group("Subway Shuffle")
## Fraction of the entry-time gap that BOTH pawns combined close across the
## choice window. 0.7 = 70 % closed by deadline, ~30 % buffer. Per-archetype
## feel knob (a Stubborn NPC could close tighter than a Commuter for character).
## Combines with `MetroMovement.shuffle_choice_time` and `Engine.time_scale`
## via `_compute_shuffle_speed` to produce a per-pawn rail speed during
## SHUFFLING that yields the same spatial closing whether bullet-time is on
## (player shuffle) or off (AI-vs-AI).
@export_range(0.0, 1.0, 0.01) var shuffle_approach_factor: float = 0.7
## Per-pawn debug toggle. Timing tunables (`shuffle_choice_time`,
## `shuffle_bullet_time_scale`) live on `MetroMovement` — single source of
## truth across all pawns — and are read via the helpers below.
@export var shuffle_debug_enabled: bool = false

# Const fallbacks used when `_metro_movement` is null (pre-registration /
# unit-test scenarios). Production code always reads from MetroMovement
# because the encounter scan only fires post-registration. Defaults match
# the MetroMovement export defaults so test scenarios feel the same.
const _SHUFFLE_CHOICE_TIME_FALLBACK: float = 2.5
const _SHUFFLE_BULLET_TIME_SCALE_FALLBACK: float = 0.2

# Run-speed and knockdown tunables live on the brain's BrainConfig Resource —
# read via brain.get_start_speed(), brain.get_max_speed(), brain.get_acceleration_time(),
# brain.get_shuffle_recovery_time(), brain.get_shuffle_get_up_time(),
# brain.get_shuffle_knockback_distance(). Different config .tres files =
# different feel per archetype with no Pawn edits.

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

# Public: -1 / 0 / +1 directional intent. Written by `lean()`; observable
# by other pawns' brains through the `lean_changed` signal or direct read.
# AIBrain consults peers' `lean_direction` when ranking lane clearance so an
# AI doesn't swerve into a lane another peer is committing to.
var lean_direction: int = 0

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

# Pending lane-change request that failed the occupancy gate. Retried every
# physics frame in _tick_running — clears as soon as it commits or another
# request_lane_change supersedes it. -1 = no pending request. Drives the
# "expand and commit when clear" UX for player input AND shared by AI brains
# (single retry path, identical surface). Cleared on locomotion exit from
# RUNNING so stale intent doesn't leak across shuffle / knockdown.
var _queued_lane_change: int = -1

# Knockdown timing. _recovery_time_left ticks down inside KNOCKED_DOWN; the
# transition DOWN → RECOVERING fires when it reaches shuffle_get_up_time and
# the visual can begin the recover animation.
var _recovery_time_left: float = 0.0

# Active shuffle bookkeeping. Non-null iff locomotion == SHUFFLING.
var shuffle: Shuffle

# Rail speed used by MetroMovement while locomotion == SHUFFLING. Computed on
# shuffle entry from the entry-time gap so combined closing across the choice
# window equals `gap × shuffle_approach_factor` regardless of bullet-time.
# Cleared by `_set_locomotion`'s SHUFFLING-exit branch.
var _shuffle_approach_speed: float = 0.0

# Engine.time_scale snapshot captured on shuffle entry (player only — gated by
# `apply_bullet_time`). Restored by `_set_locomotion`'s SHUFFLING-exit branch
# so unusual exit paths (end-of-rail, die(), failed-shuffle knockdown) all
# unwind bullet-time without each having to remember to. Decoupled from the
# `shuffle` field's lifetime — `shuffle` may be nulled before/after the
# locomotion transition; this snapshot survives it.
var _shuffle_previous_time_scale: float = 1.0

# Parking offset (applied by MetroMovement while locomotion == PARKED).
var _parked_offset: Vector3 = Vector3.ZERO

# Rail direction — set by MetroMovement at registration based on destination
# geometry. True = same direction as player (toward finish end of rail).
var _is_forward_runner: bool = true

# Camera state lives on the PawnCamera rig (rotation, headbob phase, lane-lean
# spring). Pawn passes intent via setters and per-frame snapshots in _process.

var slow_sound: AudioStreamPlayer

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	# Bind the Brain first — initial run_speed reads from brain.get_start_speed()
	# below, so the brain's config must be wired before that read.
	# Each Pawn instance owns its own Brain — PlayerBrain on the player, AIBrain
	# on NPCs. Brain decides whether this Pawn claims the camera and bullet-time
	# during _on_bound.
	brain = _find_brain_child()
	if brain != null:
		brain.bind(self)
		run_speed = brain.get_start_speed()

	if get_node_or_null("SlowSound"):
		slow_sound = get_node_or_null("SlowSound")


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
		LocomotionState.SHUFFLING:
			_tick_shuffle(delta)
		LocomotionState.RUNNING:
			_tick_running(delta)
		LocomotionState.BLOCKED:
			_try_commit_queued_lane_change()
		# PARKED / FINISHED — no per-state physics work; brain still
		# ticks below in case it wants to react via timers.
	if brain != null:
		brain.physics_tick(delta)
	if not is_on_floor():
		velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity") * delta
	else:
		velocity.y = 0.0
	# MetroMovement owns XZ via global_position; move_and_slide only resolves Y.
	velocity.x = 0.0
	velocity.z = 0.0
	move_and_slide()


# Per-state ticks. Each one is responsible for its own internal updates.

func _tick_running(delta: float) -> void:
	_update_lane_tween(delta)
	_try_commit_queued_lane_change()
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

# Brain commits to a discrete lane. Lane changes are only allowed while
# RUNNING (tween is a substate of RUNNING). Gated by `_is_lane_change_safe` —
# if the target lane has a same-direction occupant within the brain's
# `min_peer_gap` ahead, the request queues and retries every physics frame
# until safe. A subsequent `request_lane_change` overwrites the queue with
# the new target. Calling with `target_lane == _target_lane` clears any
# pending queue (cancel intent).
func request_lane_change(target_lane: int) -> void:
	if locomotion != LocomotionState.RUNNING and locomotion != LocomotionState.BLOCKED:
		return
	var clamped: int = clampi(target_lane, 0, LANE_COUNT - 1)
	if clamped == _target_lane and not _tween_active:
		_queued_lane_change = -1
		return
	if _is_lane_change_safe(clamped):
		_queued_lane_change = -1
		_commit_lane_change(clamped)
		return
	_queued_lane_change = clamped


# Per-frame retry for a queued lane change. Called from _tick_running so the
# pawn auto-commits the moment the target lane clears. No-ops when nothing is
# queued; clears the queue if it has been satisfied externally (e.g., a
# direct shuffle resolution moved us to the requested lane).
func _try_commit_queued_lane_change() -> void:
	if _queued_lane_change < 0:
		return
	if _queued_lane_change == _target_lane and not _tween_active:
		_queued_lane_change = -1
		return
	if not _is_lane_change_safe(_queued_lane_change):
		return
	var target: int = _queued_lane_change
	_queued_lane_change = -1
	_commit_lane_change(target)


# Returns true when the runner-coord scan reports `target_lane` clear of
# same-direction peers within `min_peer_gap` ahead AND no `obstacle` group
# node within the same window. Defensive defaults: no MetroMovement back-ref
# (pre-registration / unit-test scenarios) → assume safe so brains can drive
# tween tests without a registry. Same-lane request → trivially safe.
func _is_lane_change_safe(target_lane: int) -> bool:
	if target_lane == _target_lane:
		return true
	if _metro_movement == null:
		return true
	# While blocked by an obstacle the player may freely switch lanes — obstacle
	# re-detection in _advance_runner will immediately re-block if needed.
	if locomotion == LocomotionState.BLOCKED:
		return true
	var min_gap: float = brain.get_min_peer_gap() if brain != null else 1.0
	return get_lane_clearance(target_lane, min_gap) >= min_gap


# Brain initiates a shuffle encounter. This Pawn becomes the initiator.
# `gap` is the rail-distance to `other` from the encounter signal — used to
# compute slow-approach speeds so combined closing across the choice window
# equals `gap × shuffle_approach_factor` regardless of bullet-time.
# Hard guard: target must be RUNNING. If they're already SHUFFLING (busy in
# another pair), KNOCKED_DOWN, PARKED, FINISHED, etc., this is a clean no-op
# so brains can fall back to waiting / swerving without crashing the protocol
# (a 2nd `begin_subway_shuffle` call on a busy callee would silently destroy
# their existing shuffle bookkeeping).
func start_shuffle(other: Pawn, gap: float) -> void:
	if locomotion == LocomotionState.SHUFFLING or locomotion == LocomotionState.KNOCKED_DOWN or other == null:
		return
	if other.locomotion != LocomotionState.RUNNING:
		return
	# Engagement gate: both pawns must be settled in their lane (no in-flight
	# tween) before shuffle engages. Brains should gate before reaching this
	# call (PlayerBrain / AIBrain check `is_lane_settled` in
	# `_on_encounter_detected`); this guard is belt-and-braces. The encounter
	# scan keeps firing each frame, so the next signal post-tween-settles
	# re-engages naturally.
	if not is_lane_settled() or not other.is_lane_settled():
		return
	var choice_time: float = _get_shuffle_choice_time()
	shuffle = Shuffle.new()
	shuffle.is_initiator = true
	shuffle.other = other
	shuffle.deadline_msec = Time.get_ticks_msec() + int(choice_time * 1000.0)
	shuffle.time_left = choice_time
	_set_locomotion(LocomotionState.SHUFFLING)
	# Apply bullet-time BEFORE computing slow-approach speed so initiator and
	# callee both compute against the same `Engine.time_scale`.
	if apply_bullet_time:
		_shuffle_previous_time_scale = Engine.time_scale
		Engine.time_scale = _get_shuffle_bullet_time_scale()
		if brain is PlayerBrain:
			slow_sound.play()
	_shuffle_approach_speed = _compute_shuffle_speed(gap)
	if camera_rig != null:
		camera_rig.engage_shuffle_tilt(0)
	# Pass `gap` so callee computes its own approach speed against the same
	# time_scale (we just mutated it above).
	shuffle.their_telegraph = other.begin_subway_shuffle(self, shuffle.deadline_msec, gap)
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


# Brain announces a visible body lean — held lane intent during RUNNING, or
# committed shuffle telegraph during SHUFFLING. Pure body-angle intent: no
# animation clip is played here. The interact (punch) clip fires only at
# shuffle resolution — see `_complete_subway_shuffle` / `end_subway_shuffle`.
# Three side effects:
#   1. Updates `lean_direction` and emits `lean_changed` (only on actual
#      change, so observers don't churn on no-op repeats from brain ticks).
#   2. Routes to the camera rig's lane-lean spring (player-only; null on NPCs).
#      Harmless during shuffle: the rig suppresses lane lean while shuffle
#      tilt is engaged, so this only updates the dormant target until shuffle
#      ends.
#   3. Bone-lean on the torso so peers can read intent while the body keeps
#      walking. Shared by PlayerBrain (held lane key) and AIBrain (run-up tell
#      + reactive shuffle telegraph). Same surface for both — no AI-specific
#      detour.
func lean(direction: int) -> void:
	var clamped: int = clampi(direction, -1, 1)
	if clamped != lean_direction:
		lean_direction = clamped
		lean_changed.emit(clamped)
	if camera_rig != null:
		camera_rig.set_lean_direction(clamped)
	if visual != null:
		visual.set_torso_lean_only(clamped)


# Mark a Pawn as ignored for the rail-coord encounter scan until it drifts
# past the hysteresis margin (see MetroMovement.ENCOUNTER_IGNORE_HYSTERESIS).
# Used by PlayerBrain on same-direction-collision instant-knockdown so the
# scan doesn't re-trigger the same encounter on recovery. Cleared by
# MetroMovement._maybe_clear_runner_ignore.
func set_shuffle_ignored(other: Pawn) -> void:
	if _metro_movement == null:
		return
	_metro_movement.set_runner_shuffle_ignored(self, other)


# --- Rail-coord delegators (Pawn-as-facade over MetroMovement scans) ------
#
# Brains read these for lane-safety scoring, peer detection, and overtake
# decisions. Routing through Pawn means brains don't reach into Pawn's
# `_metro_movement` back-ref directly. Each helper guards the back-ref and
# returns a defensive default for pre-registration / unit-test scenarios so
# callers can stay unconditional.

# True once MetroMovement has registered this Pawn as a runner. Brains can
# guard expensive decisions (random-lane wander, overtake) on this so they
# don't act on defensive defaults during the brief window before registration
# completes.
func is_registered() -> bool:
	return _metro_movement != null


# Rail-distance to the nearest occupant (Pawn or obstacle group node) ahead
# of this Pawn in `lane`, capped at `lookahead`. INF when the lane is empty
# in scope; 0.0 when an obstacle is in the lane. Pre-registration → INF
# (assume clear) so brains can drive logic without a wired registry.
func get_lane_clearance(lane: int, lookahead: float) -> float:
	if _metro_movement == null:
		return INF
	return _metro_movement.get_lane_clearance(self, lane, lookahead)


# Same-direction Pawn ahead of this Pawn in `lane` within `lookahead` rail-meters,
# or null if none. Used for overtake decisions and same-direction speed
# modulation. Pre-registration → null.
func find_lane_occupant_ahead(lane: int, lookahead: float) -> Pawn:
	if _metro_movement == null:
		return null
	return _metro_movement.find_lane_occupant_ahead(self, lane, lookahead)


# Pawns within `lookahead` rail-meters of this Pawn (any lane). Used for
# lean-threat scoring during AI lane-safety decisions. Pre-registration →
# empty array.
func get_runners_near(lookahead: float) -> Array[Pawn]:
	if _metro_movement == null:
		return []
	return _metro_movement.get_runners_near(self, lookahead)


# --- Subway-shuffle participant hooks (called by initiator on callee) -----

func begin_subway_shuffle(from: Pawn, deadline_msec: int, gap: float) -> int:
	# Initiator already gated on `other.is_lane_settled()` in start_shuffle, so
	# we should never enter here mid-tween. No snap needed — the lane state is
	# integer-clean.
	shuffle = Shuffle.new()
	shuffle.is_initiator = false
	shuffle.other = from
	shuffle.deadline_msec = deadline_msec
	_set_locomotion(LocomotionState.SHUFFLING)
	# Initiator already mutated `Engine.time_scale` (player path) before this
	# call, so we read the post-mutation value and produce the same closing
	# distance over the wall-clock window.
	_shuffle_approach_speed = _compute_shuffle_speed(gap)
	if camera_rig != null:
		camera_rig.engage_shuffle_tilt(0)
	shuffle_began.emit(from, 0, deadline_msec)
	return shuffle.my_telegraph


func end_subway_shuffle() -> void:
	var direction: int = shuffle.my_telegraph if shuffle != null else 0
	shuffle = null
	if camera_rig != null:
		camera_rig.disengage_shuffle_tilt()
	# Symmetric with initiator's _complete_subway_shuffle: callee actually
	# lane-changes by its committed direction (no more world-space side-step
	# that snapped back). _set_locomotion(RUNNING) → lean(0) reset → visual
	# interact cue → request_lane_change (gated by safety + queue, so we
	# never resolve onto an already-occupied lane). Direction == 0 means we
	# never committed (passive resolve where the OTHER party stepped aside)
	# — just walk on.
	_set_locomotion(LocomotionState.RUNNING)
	if visual != null:
		if direction < 0:
			visual.play_interact_left()
		elif direction > 0:
			visual.play_interact_right()
		else:
			visual.play_walk()
	if direction != 0:
		request_lane_change(_target_lane + direction)


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


# True when this pawn is in RUNNING locomotion AND not mid-lane-tween. Brains
# gate `start_shuffle` on this so shuffles only engage from a settled lane —
# avoids the visual teleport that the old `_snap_tween_to_target_if_active`
# path produced when the encounter signal fired during a lane change.
func is_lane_settled() -> bool:
	return locomotion == LocomotionState.RUNNING and not _tween_active


# Shuffle window (s, wall-clock). Read from MetroMovement so every Pawn agrees
# on a single value. Falls back to a const if the back-ref is null — production
# paths always have it set by the time the encounter scan fires.
func _get_shuffle_choice_time() -> float:
	if _metro_movement == null:
		push_warning("Pawn._get_shuffle_choice_time: no MetroMovement back-ref, using fallback.")
		return _SHUFFLE_CHOICE_TIME_FALLBACK
	return _metro_movement.get_shuffle_choice_time()


# Engine.time_scale multiplier applied during the shuffle when this Pawn has
# `apply_bullet_time = true` (player only). Same back-ref + fallback model as
# `_get_shuffle_choice_time`.
func _get_shuffle_bullet_time_scale() -> float:
	if _metro_movement == null:
		push_warning("Pawn._get_shuffle_bullet_time_scale: no MetroMovement back-ref, using fallback.")
		return _SHUFFLE_BULLET_TIME_SCALE_FALLBACK
	return _metro_movement.get_shuffle_bullet_time_scale()


# Compute per-pawn rail speed for slow-approach during SHUFFLING. Both pawns
# (initiator + callee) call this with the same `gap` and the same Engine.time_scale
# (the initiator mutates time_scale before the callee's call). Result: combined
# closing distance across the window equals `gap × shuffle_approach_factor`,
# regardless of bullet-time.
#
# Math:
#   game_time_window = shuffle_choice_time × Engine.time_scale  (game-time seconds)
#   per_pawn_closing = (gap × factor) / 2
#   speed            = per_pawn_closing / game_time_window
#                    = (gap × factor) / (shuffle_choice_time × time_scale × 2)
#
# Clamped to brain.get_max_speed() defensively — entry is bounded by
# `inner_shuffle_radius` upstream, but we don't trust unbounded gaps to
# produce sane speeds.
func _compute_shuffle_speed(gap: float) -> float:
	var window: float = maxf(_get_shuffle_choice_time() * Engine.time_scale, 0.001)
	var raw: float = (gap * shuffle_approach_factor) / window / 2.0
	if brain == null:
		return maxf(raw, 0.0)
	var ceiling: float = brain.get_max_speed()
	if ceiling <= 0.0:
		return maxf(raw, 0.0)
	return clampf(raw, 0.0, ceiling)



# Current along-rail speed (m/s). MetroMovement queries this for every runner.
# Player → PlayerBrain returns pawn.run_speed (the start_speed→max_speed curve).
# NPC    → AIBrain returns its jittered _actual_move_speed.
# SHUFFLING → `_shuffle_approach_speed` (slow-approach), bypassing the brain
#   so speed-modulation / waiting-for logic doesn't apply during the window.
func get_rail_speed() -> float:
	if locomotion == LocomotionState.SHUFFLING:
		return _shuffle_approach_speed
	if brain == null:
		return 0.0
	return brain.get_move_speed()


# Read the player's start_speed→max_speed accelerator curve. PlayerBrain reads
# this in `get_move_speed` to forward to MetroMovement. Stays a plain accessor
# (no bounds check) — the field's only writer is Pawn itself + `set_run_speed`.
func get_run_speed() -> float:
	return run_speed


# Throttle / reset the accelerator curve. Brain calls this when the pawn must
# visibly halt (waiting behind a SHUFFLING peer) or restart from rest after a
# transition. Clamped non-negative; brain supplies the value (typically
# `config.start_speed` for "restart from idle").
func set_run_speed(value: float) -> void:
	run_speed = maxf(value, 0.0)


# The peer this Pawn is currently shuffling with, or null if no shuffle is
# active. AIBrain reads this for the stance-reroll loop to consult the peer's
# lean direction. Encapsulates `shuffle.other` so brains never touch the
# Shuffle bookkeeping directly.
func get_shuffle_other() -> Pawn:
	return shuffle.other if shuffle != null else null


func get_shuffle_telegraph() -> int:
	return shuffle.my_telegraph if shuffle != null else 0


# Anything other than RUNNING counts as paused — including SHUFFLING, PARKED,
# FINISHED, and BLOCKED. AIBrain / PlayerBrain use this for "is this peer in
# a normal-locomotion state I can shuffle / catch up to" decisions. SHUFFLING
# peers are still considered paused at the brain level (they're locked into
# a different encounter); only `_advance_runner` uses `is_advancing_paused()`
# below to keep them physically advancing during the window.
func is_runner_paused() -> bool:
	return locomotion != LocomotionState.RUNNING


# Locomotion states where MetroMovement should NOT advance the runner along
# the rail. SHUFFLING falls through (pawn closes the gap during slow-approach);
# everything else (KNOCKED_DOWN / PARKED / FINISHED / BLOCKED / DISABLED) is
# physically frozen. Equivalent to "locomotion != RUNNING and != SHUFFLING"
# but spelled out to keep intent obvious.
func is_advancing_paused() -> bool:
	return (
		locomotion == LocomotionState.KNOCKED_DOWN
		or locomotion == LocomotionState.PARKED
		or locomotion == LocomotionState.FINISHED
		or locomotion == LocomotionState.BLOCKED
		or locomotion == LocomotionState.DISABLED
	)


func is_routing_to_finish_point() -> bool:
	return _is_forward_runner


func set_rail_forward(value: bool) -> void:
	_is_forward_runner = value


func is_shuffle_active() -> bool:
	return locomotion == LocomotionState.SHUFFLING


func should_avoid_obstacles() -> bool:
	if brain == null:
		return false
	# Suspend obstacle scanning while SHUFFLING. With Stage 5 slow-approach
	# the pawn advances during the shuffle window; an obstacle hit mid-shuffle
	# would call PlayerBrain → knock_down_from_shuffle on self, leaving the
	# callee stuck in SHUFFLING with no resolver. The shuffle either resolves
	# at deadline or transitions out via _set_locomotion's cleanup. After exit,
	# obstacle scanning returns; if the obstacle is still in lane it'll fire
	# next frame.
	if locomotion == LocomotionState.SHUFFLING:
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
		run_speed = brain.get_start_speed() if brain != null else 0.0
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
	var recovery_time: float = brain.get_shuffle_recovery_time() if brain != null else 0.0
	var get_up_time: float = brain.get_shuffle_get_up_time() if brain != null else 0.0
	_recovery_time_left = maxf(recovery_time, get_up_time)
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


# Push this Pawn back from the impact origin by brain.get_shuffle_knockback_distance().
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
	var knockback: float = brain.get_shuffle_knockback_distance() if brain != null else 0.0
	global_position += direction * knockback


func _update_knockdown_recovery(delta: float) -> void:
	if _recovery_time_left > 0.0:
		_recovery_time_left = maxf(0.0, _recovery_time_left - delta)
	# DOWN → RECOVERING: get-up window opened and visual is ready to play recover.
	var get_up_time: float = brain.get_shuffle_get_up_time() if brain != null else 0.0
	if knockdown_phase == KnockdownPhase.DOWN \
			and _recovery_time_left <= get_up_time \
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
	run_speed = brain.get_start_speed() if brain != null else 0.0
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
	# Reset lean_direction when exiting an active-intent state into RUNNING so
	# the broadcast stays in sync with what the body is actually doing. Without
	# this, peer brains reading `lean_direction` get stale telegraph values
	# from the just-finished shuffle / knockdown — AIBrain's lane-safety
	# scoring would then treat a neutral pawn as if it were still committing.
	if new_state == LocomotionState.RUNNING and (
			old_state == LocomotionState.SHUFFLING
			or old_state == LocomotionState.KNOCKED_DOWN):
		lean(0)
	# Clear queued lane change on RUNNING exit — stale intent shouldn't leak
	# across shuffle / knockdown / parked / finished. Brain re-issues if it
	# still wants the change after returning to RUNNING.
	if old_state == LocomotionState.RUNNING and new_state != LocomotionState.RUNNING:
		_queued_lane_change = -1
	# Centralized SHUFFLING-exit cleanup. Single source of truth so unusual exit
	# paths (end-of-rail mid-shuffle, die() during shuffle, future BLOCKED
	# transitions) restore Engine.time_scale and clear shuffle-driven rail speed.
	# Uses the Pawn-owned `_shuffle_previous_time_scale` snapshot rather than
	# the `shuffle` field — decoupling the cleanup from `shuffle`'s lifetime
	# (some resolve paths null `shuffle` before the locomotion transition).
	if old_state == LocomotionState.SHUFFLING and new_state != LocomotionState.SHUFFLING:
		if apply_bullet_time:
			Engine.time_scale = _shuffle_previous_time_scale
		_shuffle_approach_speed = 0.0


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
	if locomotion == LocomotionState.BLOCKED:
		run_speed = brain.get_start_speed() if brain != null else 0.0
		_set_locomotion(LocomotionState.RUNNING)
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


func _resolve_subway_shuffle() -> void:
	if shuffle == null:
		return
	if shuffle.other != null:
		shuffle.their_telegraph = shuffle.other.get_shuffle_telegraph()
	var collision: bool = _shuffle_choices_collide()
	# Symmetric: succeed if neither side picks a colliding world-side AND at
	# least one side committed. A passive initiator with a committed callee
	# now succeeds (the callee steps aside via its own lane change). Both
	# passive = collision (neither moved → still in same lane).
	var any_committed: bool = shuffle.my_telegraph != 0 or shuffle.their_telegraph != 0
	var succeeded: bool = any_committed and not collision
	if succeeded:
		_complete_subway_shuffle(shuffle.my_telegraph)
	else:
		_fail_subway_shuffle()


func _complete_subway_shuffle(direction: int) -> void:
	# Engine.time_scale + _shuffle_approach_speed cleanup runs in
	# _set_locomotion's SHUFFLING-exit branch (single source of truth).
	run_speed = brain.get_start_speed() if brain != null else 0.0
	var other: Pawn = shuffle.other
	if other != null:
		other.end_subway_shuffle()
		# One-sided ignore by design: only the initiator skips the callee on
		# its next scan. The callee's scan stays live so a same-lane outcome
		# (e.g. initiator clamped at an edge lane) intentionally cascades into
		# a fresh callee-initiated shuffle. Awkward, but emergent.
		set_shuffle_ignored(other)
	shuffle = null
	if camera_rig != null:
		camera_rig.disengage_shuffle_tilt()
	_set_locomotion(LocomotionState.RUNNING)
	# Gated lane change — request_lane_change queues if the resolved target
	# lane is occupied by a same-direction peer. Pawn stays put until safe
	# rather than overlapping.
	request_lane_change(_target_lane + direction)
	if direction < 0 and visual != null:
		visual.play_interact_left()
	elif direction > 0 and visual != null:
		visual.play_interact_right()
	shuffle_resolved.emit(true, direction)


func _fail_subway_shuffle() -> void:
	# Engine.time_scale + _shuffle_approach_speed cleanup runs in
	# _set_locomotion's SHUFFLING-exit branch (triggered below by
	# knock_down_from_shuffle → _set_locomotion(KNOCKED_DOWN)).
	run_speed = brain.get_start_speed() if brain != null else 0.0
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
	if shuffle == null or shuffle.other == null:
		return false
	# Both passive → neither stepped, still in the same lane → collision.
	if shuffle.my_telegraph == 0 and shuffle.their_telegraph == 0:
		return true
	# Exactly one party committed → that party steps aside; no collision.
	# The committed pawn's lane change handles geometry on resolution.
	if shuffle.my_telegraph == 0 or shuffle.their_telegraph == 0:
		return false
	# Both committed → check whether their world-side picks coincide.
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
	if brain == null:
		return
	var max_speed: float = brain.get_max_speed()
	var acceleration_time: float = brain.get_acceleration_time()
	if run_speed < max_speed and acceleration_time > 0.0:
		var rate: float = (max_speed - brain.get_start_speed()) / acceleration_time
		run_speed = min(max_speed, run_speed + rate * delta)


# Camera math (pitch input, headbob, lane lean, shuffle tilt) lives on the
# PawnCamera rig — Pawn drives intent only:
#   - _input forwards mouse motion via camera_rig.apply_pitch_input
#   - _process forwards effective speed + lane tween snapshot each frame
#   - lean() forwards held lane intent via set_lean_direction
#   - shuffle entry / telegraph change → engage_shuffle_tilt(direction)
#   - knockdown entry → engage_shuffle_tilt(0)   (rolls back to upright)
#   - shuffle resolved / recovery → disengage_shuffle_tilt
