class_name PlayerBrain
extends Brain

# Player brain. Reads keyboard input via process_input forwarded from Pawn
# and translates it into Pawn intent calls (request_lane_change /
# set_shuffle_telegraph / lean). Owns all player-specific concerns that used
# to live on Pawn: bullet-time mutation, mouse capture, camera-mode flips on
# knockdown / recovery, slow_sound playback. Pawn fires
# `on_shuffle_entered` / `on_shuffle_exited` / `on_knocked_down` /
# `on_recovered` from `_set_locomotion`; PlayerBrain handles them. NPCs use
# the default no-op implementations on `Brain` and never touch these systems.
#
# All tunables live on the assigned `PlayerBrainConfig` Resource. PlayerBrain
# itself has zero @exports beyond the config slot — body feel + sensing
# lookaheads come from BrainConfig (the base type) via config.<field>.

## Per-archetype tunables. Authored as a .tres under
## Scenes/Characters/Brains/Configs/DefaultPlayer.tres. Required; null-config
## falls back to PlayerBrainConfig.new() defaults with a push_error.
@export var config: PlayerBrainConfig

var _lane_intent: int = 0

# Engine.time_scale snapshot taken on shuffle entry, restored on shuffle exit.
# Lives here (not on Pawn) because only PlayerBrain mutates Engine.time_scale —
# `apply_bullet_time` flag is gone post-Stage-3. Survives the locomotion
# transition because the snapshot is per-PlayerBrain-instance, not tied to the
# `Shuffle` struct's lifetime.
var _shuffle_previous_time_scale: float = 1.0


func _on_bound() -> void:
	if config == null:
		push_error("PlayerBrain on '%s' has no config — using PlayerBrainConfig.new() defaults." % pawn.name)
		config = PlayerBrainConfig.new()
	pawn.add_to_group("player")
	# Resolve the singleton PlayerCamera (lives at level scene root, in group
	# "player_camera"), wire it to this Pawn. NPCs never run this branch, so
	# the rig has exactly one target ever.
	var rig: PawnCamera = pawn.get_tree().get_first_node_in_group("player_camera") as PawnCamera
	if rig != null:
		pawn.camera_rig = rig
		rig.set_target(pawn)
		rig.set_active(true)
	else:
		push_warning("PlayerBrain: no PawnCamera in group \"player_camera\" — camera intents will no-op.")
	# Capture the mouse for first-person look. Toggled by ui_cancel in
	# `process_input` below.
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# Hide the Pawn's visual — first-person means the player's body is
	# off-screen. Re-shown on knockdown (death anim), re-hidden on recovery
	# via `on_knocked_down` / `on_recovered`.
	if pawn.visual != null:
		pawn.visual.hide()


# Player wants MetroMovement to scan for environment obstacles every frame.
# When something is in the lane, _on_obstacle_detected handles the response.
func should_avoid_obstacles() -> bool:
	return true


func get_obstacle_lookahead() -> float:
	return config.obstacle_lookahead


func get_encounter_lookahead() -> float:
	return config.encounter_lookahead


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


func _on_obstacle_detected(_blocker: Node, _distance: float, _in_lane: int, _candidate_lanes: Array[int]) -> void:
	pawn.set_movement_blocked(true)


func get_end_of_rail_action() -> int:
	return EndOfRailAction.GOAL


# --- Locomotion-transition hooks (player-specific concerns) ---------------

# Shuffle entry: snapshot + apply bullet-time, play slow_sound, engage camera
# shuffle tilt with neutral target. Fires from `Pawn._set_locomotion(SHUFFLING)`
# BEFORE `start_shuffle` reads `Engine.time_scale` to compute the slow-approach
# rail speed — both initiator and callee compute against the post-mutation value.
func on_shuffle_entered() -> void:
	_shuffle_previous_time_scale = Engine.time_scale
	Engine.time_scale = pawn._get_shuffle_bullet_time_scale()
	if pawn.slow_sound != null:
		pawn.slow_sound.play()
	if pawn.camera_rig != null:
		pawn.camera_rig.engage_shuffle_tilt(0)


# Shuffle exit: restore time_scale, disengage camera shuffle tilt. Pairs with
# `on_knocked_down` for the failed-shuffle path — both fire on
# SHUFFLING → KNOCKED_DOWN, in that order. `on_knocked_down` re-engages tilt
# with target 0 immediately after, so the camera holds tilt mode through the
# fall.
func on_shuffle_exited() -> void:
	Engine.time_scale = _shuffle_previous_time_scale
	if pawn.camera_rig != null:
		pawn.camera_rig.disengage_shuffle_tilt()


# Knockdown entry: hold camera in shuffle-tilt mode with target 0 so it rolls
# upright as the player falls (lane lean is suppressed while tilt is engaged).
# Flip to third-person so the player can see their own body's death anim.
func on_knocked_down() -> void:
	if pawn.camera_rig != null:
		pawn.camera_rig.engage_shuffle_tilt(0)
		pawn.camera_rig.apply_mode(PawnCamera.Mode.THIRD_PERSON)


# Recovery completion: disengage shuffle tilt (hand rotation.z back to the
# lane-lean spring), flip back to first-person, re-hide the visual.
func on_recovered() -> void:
	if pawn.camera_rig != null:
		pawn.camera_rig.disengage_shuffle_tilt()
		pawn.camera_rig.apply_mode(PawnCamera.Mode.FIRST_PERSON)
	if pawn.visual != null:
		pawn.visual.hide()


# Player's current speed lives on Pawn (start_speed → max_speed acceleration
# curve, mutated by knockdown / movement_blocked / goal_reached). MetroMovement
# queries every runner through this method, so PlayerBrain forwards Pawn's
# physical speed instead of owning a separate value — modulated through the
# Brain-base helpers: same-direction peer match (cap at peer speed) and busy-
# peer wait (zero until peer is lane-settled).
func get_move_speed() -> float:
	return modulate_for_wait(modulate_for_same_direction_peer(pawn.get_run_speed()))


# Called by Pawn._input for every input event. Handles three concerns:
#   1. Mouse pitch — applied to the camera rig (gated by `can_look`).
#   2. ui_cancel — toggle mouse capture so the user can interact with overlays.
#   3. Lane input — left/right routed to shuffle telegraph (during SHUFFLING)
#      or lane press/release intent (otherwise).
# The mouse handling lived on Pawn pre-Stage-3; it's player-specific so it
# moved here. NPCs use the default no-op `process_input` on Brain.
func process_input(event: InputEvent) -> void:
	if pawn == null:
		return
	# Mouse pitch + ui_cancel toggle. Camera rig is null on NPCs but PlayerBrain
	# only runs on the player Pawn, which always has it (post-bind).
	if pawn.camera_rig != null:
		if pawn.can_look() and event is InputEventMouseMotion:
			var motion: InputEventMouseMotion = event as InputEventMouseMotion
			pawn.camera_rig.apply_pitch_input(motion.relative.y)
		if event.is_action_pressed("ui_cancel"):
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
					else Input.MOUSE_MODE_CAPTURED
	if pawn.locomotion == Pawn.LocomotionState.SHUFFLING:
		if event.is_action_pressed("left") or event.is_action_pressed("right") \
				or event.is_action_released("left") or event.is_action_released("right"):
			var held: int = _get_held_direction()
			pawn.set_shuffle_telegraph(held)
			pawn.lean(held)
		return
	# Lane input only flows during RUNNING or BLOCKED (cutscene-pause). KNOCKED_DOWN /
	# FINISHED / PARKED / DISABLED / SHUFFLING all reject input here.
	if not pawn.is_running() and pawn.locomotion != Pawn.LocomotionState.BLOCKED:
		return
	if event.is_action_pressed("left"):
		_on_lane_input_press(-1)
	elif event.is_action_pressed("right"):
		_on_lane_input_press(1)
	elif event.is_action_released("left") or event.is_action_released("right"):
		_on_lane_input_release()


func _on_lane_change_canceled() -> void:
	# A shuffle interrupted our tween — reset camera-lean intent.
	_lane_intent = 0
	pawn.lean(0)


func _on_recovered() -> void:
	# Require a fresh press to lane-change after recovery.
	_lane_intent = 0
	pawn.lean(0)


func _on_encounter_detected(other: Pawn, distance: float) -> void:
	if other == null:
		return
	# Same-direction peer (NPC walking the same way as the player): no
	# shuffle, no knockdown — get_move_speed caps us at their speed so we
	# trail them. Knockback should only fire on head-on collisions.
	if other.is_routing_to_finish_point() == pawn.is_routing_to_finish_point():
		_waiting_for = null
		return
	# Opposing pawn already in another shuffle: halt and wait. Their shuffle
	# resolves in <0.5s; `_waiting_for` clears the moment they're RUNNING +
	# lane-settled and the encounter scan's next tick re-engages.
	if other.locomotion == Pawn.LocomotionState.SHUFFLING:
		_wait_for(other)
		return
	_waiting_for = null
	# Other paused states (KNOCKED_DOWN, PARKED, FINISHED, DISABLED): no
	# shuffle, just walk past. Encounter scan re-fires, but with a paused
	# peer we never engage — the body is geometry to navigate around.
	if not other.is_running():
		return
	# Outside the engagement zone: keep closing. Encounter scan re-fires
	# every frame, so we engage the moment we're inside.
	if distance > config.inner_shuffle_radius:
		return
	# Inside the zone with an opposing RUNNING pawn in the same occupied lane.
	# `start_shuffle` no-ops if either side is mid-tween — the encounter scan
	# re-fires every frame, so the next tick after both settle engages
	# naturally. The scan reads occupied lane (rounded `_lane_position`), so a
	# pawn swerving away is dropped from this signal once they've crossed
	# half the lane width.
	pawn.start_shuffle(other, distance)


# Press handler — set lane intent. Cancels intent if both keys are now held.
func _on_lane_input_press(direction: int) -> void:
	# Allow input only during RUNNING or BLOCKED. KNOCKED_DOWN, FINISHED,
	# PARKED, SHUFFLING, DISABLED all reject — same gate as `process_input`.
	if not pawn.is_running() and pawn.locomotion != Pawn.LocomotionState.BLOCKED:
		return
	var both_held: bool = Input.is_action_pressed("left") and Input.is_action_pressed("right")
	_lane_intent = 0 if both_held else direction
	pawn.lean(_lane_intent)


# Release handler — commit the lane change if no other key is still held.
func _on_lane_input_release() -> void:
	var still_held: bool = Input.is_action_pressed("left") or Input.is_action_pressed("right")
	if still_held:
		_lane_intent = -1 if Input.is_action_pressed("left") else 1
		pawn.lean(_lane_intent)
		return
	if pawn.is_running() or pawn.locomotion == Pawn.LocomotionState.BLOCKED:
		var next_lane: int = clampi(pawn.get_current_lane() + _lane_intent, 0, Pawn.LANE_COUNT - 1)
		if next_lane != pawn.get_current_lane():
			# Player skips the telegraph prefix — the keyboard hold IS the
			# telegraph. Adding 0.3s of standing-still-while-leaning before
			# the swerve would also delay shuffle engagement past the point
			# where opposing pawns collide. AI swerves keep the prefix
			# (default INF clamps to the configured ratio).
			pawn.request_lane_change(next_lane, 0.0)
	_lane_intent = 0
	pawn.lean(0)


func _get_held_direction() -> int:
	var direction: int = 0
	if Input.is_action_pressed("left"):
		direction -= 1
	if Input.is_action_pressed("right"):
		direction += 1
	return clampi(direction, -1, 1)
