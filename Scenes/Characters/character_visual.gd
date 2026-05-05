class_name CharacterVisual
extends Node3D

enum MotionState { WALK, SPRINT, INTERACT_LEFT, INTERACT_RIGHT, DIE, RECOVER }

const STATE_NAMES: Dictionary[int, String] = {
	MotionState.WALK: "walk",
	MotionState.SPRINT: "sprint",
	MotionState.INTERACT_LEFT: "interact-left",
	MotionState.INTERACT_RIGHT: "interact-right",
	MotionState.DIE: "die",
	MotionState.RECOVER: "recover",
}

const ANIMATION_NAMES: Dictionary[int, String] = {
	MotionState.WALK: "Walk_Loop RT",
	MotionState.SPRINT: "Walk_Loop RT",
	MotionState.INTERACT_LEFT: "Fighting Left Jab RT",
	MotionState.INTERACT_RIGHT: "Fighting Right Jab RT",
	MotionState.DIE: "Hit_Knockback RT",
	MotionState.RECOVER: "Idle_FoldArms_Loop RT",
}

const MOTION_STATES: Array[int] = [
	MotionState.WALK,
	MotionState.SPRINT,
	MotionState.INTERACT_LEFT,
	MotionState.INTERACT_RIGHT,
	MotionState.DIE,
	MotionState.RECOVER,
]

@export var walk_speed_threshold: float = 2.5
@export var playback_fade_time: float = 0.15
## Peak lean angle in radians. ~0.5 rad ≈ 28°: dramatic and unmistakable. The
## body tilts in z (lateral lean) by `torso_lean_amount × _torso_lean_direction`.
@export var torso_lean_amount: float = 0.5
## Lerp speed (radians/second-ish). Higher = snappier. 8.0 reaches ~95% of
## target in ~0.4s at 60fps.
@export var torso_lean_speed: float = 8.0
## When true, lean ignores Engine.time_scale so it stays snappy during bullet-time.
## Set false on NPCs so their lean feels slow and dramatic in bullet-time.
@export var lean_ignore_time_scale: bool = true
## When true, every direction change emits a `[lean]` print so we can verify
## the intent is reaching the visual layer. ON during the lean-tuning pass.
@export var lean_debug_log: bool = true
@export var skeleton: Skeleton3D
@export var animation_player: AnimationPlayer

@onready var animation_tree: AnimationTree = $AnimationTree
@onready var model_root: Node3D = $ModelRoot

var _playback: AnimationNodeStateMachinePlayback
var _state: int = MotionState.WALK
var _current_torso_lean: float = 0.0
var _state_lock_time: float = 0.0
var _locked_state: int = -1
var _torso_lean_direction: int = 0


# Build the reusable animation state machine after child nodes are ready.
# We rotate `model_root` (a plain Node3D parent of the rig) rather than
# overriding a bone pose — sidesteps the AnimationTree clobber entirely and
# works regardless of rig export naming.
func _ready() -> void:
	process_priority = 100
	_force_locomotion_loop()
	_configure_animation_tree()
	play_walk()


# Walk and sprint must loop. GLB clips import without loop_mode set by default;
# set it here so the AnimationTree state machine never freezes on either clip.
func _force_locomotion_loop() -> void:
	for state: int in [MotionState.WALK, MotionState.SPRINT]:
		var anim_name: String = _get_animation_name(state)
		if animation_player.has_animation(anim_name):
			animation_player.get_animation(anim_name).loop_mode = Animation.LOOP_LINEAR


# Blend the torso lean after animation playback updates the skeleton.
func _process(delta: float) -> void:
	_state_lock_time = maxf(0.0, _state_lock_time - delta)
	_update_torso_lean(delta)


# Set locomotion animation from current movement speed.
func set_move_speed(speed: float) -> void:
	if _state_lock_time > 0.0 or _state == MotionState.DIE:
		return
	if speed >= walk_speed_threshold:
		play_sprint()
	else:
		play_walk()


# Play the normal forward walking state. Lean direction is owned by Pawn
# (driven via `set_torso_lean_only`) and is independent of locomotion clip
# choice — the spine z-override rides on top of the WALK clip. Don't reset
# it here, or per-frame `Pawn._tick_running` calls to `set_move_speed` will
# zero out a brain's intent every physics tick and the body never tilts.
func play_walk() -> void:
	if _is_recovery_state_locked():
		return
	_travel(MotionState.WALK)


# Faster locomotion clip — same independence from torso lean as `play_walk`.
func play_sprint() -> void:
	if _is_recovery_state_locked():
		return
	_travel(MotionState.SPRINT)


# Play a left-side interaction dodge/shuffle animation.
func play_interact_left() -> void:
	if _is_recovery_state_locked():
		return
	_travel(MotionState.INTERACT_LEFT)
	_lock_state_for_animation(MotionState.INTERACT_LEFT)


# Play a right-side interaction dodge/shuffle animation.
func play_interact_right() -> void:
	if _is_recovery_state_locked():
		return
	_travel(MotionState.INTERACT_RIGHT)
	_lock_state_for_animation(MotionState.INTERACT_RIGHT)


# Set the lean direction without changing animation state. Used by Pawn to
# drive both the brain-intent lean and the lane-tween's step direction.
# Body keeps walking; `model_root.rotation.z` lerps toward the new target.
func set_torso_lean_only(direction: int) -> void:
	var clamped: int = clampi(direction, -1, 1)
	if clamped == _torso_lean_direction:
		return
	_torso_lean_direction = clamped
	if lean_debug_log:
		var owner_name: String = get_parent().name if get_parent() != null else "?"
		print("[lean] %s dir=%d (state=%s)" % [owner_name, clamped, _get_state_name(_state)])


# Play the death animation. Lean direction is preserved (the lerp drives to
# 0 while DIE owns the upper body — see `_update_torso_lean`'s gate).
func play_die() -> void:
	if _state == MotionState.DIE and _is_recovery_state_locked():
		return
	_travel(MotionState.DIE)
	_lock_state_for_animation(MotionState.DIE)


# Play the collision recovery animation. Same lean handling as `play_die`.
func play_recover() -> void:
	if _is_recovery_state_locked():
		return
	_travel(MotionState.RECOVER)
	_lock_state_for_animation(MotionState.RECOVER)


# Return whether the recover animation can start now.
func can_start_recover() -> bool:
	return not _is_recovery_state_locked()


# Return whether die or recover is still owning animation playback.
func is_recovery_locked() -> bool:
	return _is_recovery_state_locked()


# Enable use_custom_timeline on the walk AnimationNodeAnimation and set a
# random timeline_length so each NPC loops at a different rate, breaking sync.
func randomize_animation_offset(min_length: float = 0.75, max_length: float = 1.25) -> void:
	if animation_tree == null or animation_tree.tree_root == null:
		return
	var state_machine: AnimationNodeStateMachine = animation_tree.tree_root as AnimationNodeStateMachine
	if state_machine == null:
		return
	var walk_state_name: String = _get_state_name(MotionState.WALK)
	var walk_node: AnimationNodeAnimation = state_machine.get_node(walk_state_name) as AnimationNodeAnimation
	if walk_node == null:
		return
	walk_node.use_custom_timeline = true
	var walk_speed: float = snappedf(randf_range(min_length, max_length), 0.01)
	walk_node.timeline_length = walk_speed
	walk_node.loop_mode = Animation.LOOP_LINEAR


# Freeze the animation tree on its current pose (e.g., when an NPC arrives
# at the train and stands idle). Locomotion state is preserved so a later
# resume_animation() resumes the same clip.
func pause_animation() -> void:
	if animation_tree != null:
		animation_tree.active = false


# Resume a previously paused animation tree.
func resume_animation() -> void:
	if animation_tree != null:
		animation_tree.active = true


# Configure an AnimationTree state machine using local clips.
func _configure_animation_tree() -> void:
	if animation_tree.tree_root == null:
		animation_tree.tree_root = _create_animation_state_machine()
	animation_tree.anim_player = animation_tree.get_path_to(animation_player)
	animation_tree.active = true
	_playback = animation_tree.get("parameters/playback")


# Create the fallback state machine when one was not serialized in the scene.
func _create_animation_state_machine() -> AnimationNodeStateMachine:
	var state_machine: AnimationNodeStateMachine = AnimationNodeStateMachine.new()
	for state: int in MOTION_STATES:
		var animation_node: AnimationNodeAnimation = AnimationNodeAnimation.new()
		animation_node.animation = StringName(_get_animation_name(state))
		state_machine.add_node(_get_state_name(state), animation_node)

	for from_state: int in MOTION_STATES:
		for to_state: int in MOTION_STATES:
			if from_state == to_state:
				continue
			var transition: AnimationNodeStateMachineTransition = AnimationNodeStateMachineTransition.new()
			transition.xfade_time = playback_fade_time
			state_machine.add_transition(_get_state_name(from_state), _get_state_name(to_state), transition)
	return state_machine


# Move to a state if the target clip is available.
func _travel(state: int) -> void:
	var state_name: StringName = _get_state_name(state)
	var animation_name: String = _get_animation_name(state)

	if _playback != null:
		_playback.travel(state_name)
	elif animation_player.has_animation(animation_name):
		animation_player.play(animation_name)
	_state = state


# Prevent locomotion updates from immediately replacing a one-shot state.
func _lock_state_for_animation(state: int) -> void:
	var animation_name: String = _get_animation_name(state)
	if animation_player.has_animation(animation_name):
		_state_lock_time = animation_player.get_animation(animation_name).length
		_locked_state = state


# Return whether die or recover animation playback should ignore state changes.
func _is_recovery_state_locked() -> bool:
	if _state_lock_time <= 0.0:
		_locked_state = -1
		return false
	return _locked_state == MotionState.DIE or _locked_state == MotionState.RECOVER


# Lerp the model_root's z-rotation toward `_torso_lean_direction × torso_lean_amount`.
# This rotates the entire rig — sidesteps the AnimationTree-vs-bone-pose
# fight entirely. Visually identical to a torso-only lean for our use case
# (the rig is roughly upright; tilting the whole body in z reads as a body
# lean). WALK / SPRINT clips don't drive z either, so they coexist cleanly.
#
# Skipped during clips that own the upper body (INTERACT_* / DIE / RECOVER)
# so the punch / knockback / get-up poses aren't pre-tilted by leftover lean.
#
# `lean_ignore_time_scale` rescales delta by 1/time_scale so the lean still
# snaps in visible wall-clock time during bullet-time shuffles. NPC scenes
# set this false — granny's slow lean during bullet-time is part of the feel.
func _update_torso_lean(delta: float) -> void:
	var owns_upper_body: bool = (
		_state == MotionState.INTERACT_LEFT
		or _state == MotionState.INTERACT_RIGHT
		or _state == MotionState.DIE
		or _state == MotionState.RECOVER
	)
	var target_lean: float = 0.0 if owns_upper_body else torso_lean_amount * float(_torso_lean_direction)
	var effective_delta: float = delta / maxf(Engine.time_scale, 0.01) if lean_ignore_time_scale else delta
	var weight: float = clamp(torso_lean_speed * effective_delta, 0.0, 1.0)
	_current_torso_lean = lerp(_current_torso_lean, target_lean, weight)
	if abs(_current_torso_lean) < 0.001 and is_zero_approx(target_lean):
		_current_torso_lean = 0.0
	if model_root != null:
		model_root.rotation.z = _current_torso_lean


# Return the state name used in the blend tree.
func _get_state_name(state: int) -> String:
	var state_name: String = STATE_NAMES.get(state, "walk")
	return state_name


# Return the animation clip name for a state.
func _get_animation_name(state: int) -> String:
	return ANIMATION_NAMES.get(state, "Walk_Loop RT")
