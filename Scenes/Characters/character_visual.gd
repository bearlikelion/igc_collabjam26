class_name CharacterVisual
extends Node3D

enum MotionState { WALK, SPRINT, INTERACT_LEFT, INTERACT_RIGHT, DIE, RECOVER, IDLE }

# IDLE shares the "recover" state-machine node — both play
# `Idle_FoldArms_Loop RT` and every shipped scene already wires "recover"
# transitions. The script-level distinction keeps lock semantics separate:
# RECOVER state-locks (post-knockdown), IDLE doesn't (transient halt).
const STATE_NAMES: Dictionary[int, String] = {
	MotionState.WALK: "walk",
	MotionState.SPRINT: "sprint",
	MotionState.INTERACT_LEFT: "interact-left",
	MotionState.INTERACT_RIGHT: "interact-right",
	MotionState.DIE: "die",
	MotionState.RECOVER: "recover",
	MotionState.IDLE: "recover",
}

const ANIMATION_NAMES: Dictionary[int, String] = {
	MotionState.WALK: "Walk_Loop RT",
	MotionState.SPRINT: "Walk_Loop RT",
	MotionState.INTERACT_LEFT: "Fighting Left Jab RT",
	MotionState.INTERACT_RIGHT: "Fighting Right Jab RT",
	MotionState.DIE: "Hit_Knockback RT",
	MotionState.RECOVER: "Idle_FoldArms_Loop RT",
	MotionState.IDLE: "Idle_FoldArms_Loop RT",
}

# IDLE is intentionally absent — it shares "recover"'s node, so listing it
# here would create a duplicate when `_create_animation_state_machine`
# bootstraps a tree from scratch.
const MOTION_STATES: Array[int] = [
	MotionState.WALK,
	MotionState.SPRINT,
	MotionState.INTERACT_LEFT,
	MotionState.INTERACT_RIGHT,
	MotionState.DIE,
	MotionState.RECOVER,
]

@export var walk_speed_threshold: float = 2.5
## Below this speed (m/s) the body plays the idle clip instead of the walk
## loop. Set just above 0 so floating-point noise doesn't flicker between
## idle and walk.
@export var idle_speed_threshold: float = 0.05
@export var playback_fade_time: float = 0.15
## Peak lean angle in radians. Pivot is now a mid-spine bone (via
## TorsoLeanModifier) rather than the whole rig at the feet — same number
## reads ~3× stronger at the head. ~0.30 rad (~17°) is the new sweet spot
## for NPCs; the player's Pawn.tscn overrides higher.
@export var torso_lean_amount: float = 0.30
## Lerp speed (radians/second-ish). Higher = snappier. 8.0 reaches ~95% of
## target in ~0.4s at 60fps.
@export var torso_lean_speed: float = 8.0
## Telegraph floor in radians: when the brain commits a non-zero lean
## direction, the body snaps to at least this magnitude so micro-leans never
## read as neutral. Center stays upright. ~0.10 rad ≈ 5.7° — visible but not
## jarring. Player typically overrides higher (broadcast read-back matters more).
@export var min_lean_radians: float = 0.10
## When true, lean ignores Engine.time_scale so it stays snappy during bullet-time.
## Set false on NPCs so their lean feels slow and dramatic in bullet-time.
@export var lean_ignore_time_scale: bool = true
## Bone the spine-lean is applied to. Two rig families ship in this project:
##   - NPC1 Rigify (mNPC1 / fNPC1 / player): "DEF-spine002"
##   - Mixamo-style (Doctor / Hoodie / Salaryman / Redhead / Elderly): "Chest"
## Default fits the player + CharacterVisual.tscn; Mixamo-rig NPC scenes override.
@export var spine_bone_name: String = "DEF-spine002"
@export var skeleton: Skeleton3D
@export var animation_player: AnimationPlayer

@onready var animation_tree: AnimationTree = $AnimationTree
@onready var model_root: Node3D = $ModelRoot

var _playback: AnimationNodeStateMachinePlayback
var _state: int = MotionState.WALK
var _state_lock_time: float = 0.0
var _locked_state: int = -1
var _torso_lean_direction: int = 0
var _lean_modifier: TorsoLeanModifier


# Build the reusable animation state machine after child nodes are ready.
# Torso lean is applied via a TorsoLeanModifier child of the Skeleton3D —
# SkeletonModifier3D runs after AnimationTree pose writes, so additive bone
# rotations survive the AnimationTree clobber that bites a naive _process
# write. Created programmatically so every scene that re-instances this
# script (every NPC tscn) picks it up without scene-graph fanout.
func _ready() -> void:
	process_priority = 100
	_force_locomotion_loop()
	_configure_animation_tree()
	_install_lean_modifier()
	# Defensive reset — earlier versions rotated model_root.z directly. Any
	# persisted scene-state lean should clear on load.
	if model_root != null:
		model_root.rotation.z = 0.0
	play_walk()


# Walk and sprint must loop. GLB clips import without loop_mode set by default;
# set it here so the AnimationTree state machine never freezes on either clip.
func _force_locomotion_loop() -> void:
	for state: int in [MotionState.WALK, MotionState.SPRINT]:
		var anim_name: String = _get_animation_name(state)
		if animation_player.has_animation(anim_name):
			animation_player.get_animation(anim_name).loop_mode = Animation.LOOP_LINEAR


# Drive lean intent every frame. The actual pose write happens in the
# TorsoLeanModifier; here we only decide whether the upper body is
# currently owned by an INTERACT_/DIE/RECOVER clip (in which case the lean
# target snaps to 0 so the punch / knockback / get-up poses aren't pre-tilted).
func _process(delta: float) -> void:
	_state_lock_time = maxf(0.0, _state_lock_time - delta)
	_drive_torso_lean()


# Set locomotion animation from current movement speed. Three-way picker:
#   speed >= walk_speed_threshold  → sprint
#   speed >  idle_speed_threshold  → walk
#   else                           → idle (pawn is halted — waiting behind a
#                                          peer, compressed against a slow
#                                          peer, BLOCKED, or FINISHED)
func set_move_speed(speed: float) -> void:
	if _state_lock_time > 0.0 or _state == MotionState.DIE:
		return
	if speed >= walk_speed_threshold:
		play_sprint()
	elif speed > idle_speed_threshold:
		play_walk()
	else:
		play_idle()


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


# Standing-idle clip for halted pawns. Travels to the existing "recover"
# state-machine node (shared with `play_recover`) but does NOT lock —
# transitions out via the next `set_move_speed` call once the body is
# moving again. A still pawn still leans toward held lane intent (IDLE
# is intentionally absent from `_drive_torso_lean`'s owns_upper_body set).
func play_idle() -> void:
	if _is_recovery_state_locked():
		return
	_travel(MotionState.IDLE)


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
# Body keeps walking; the TorsoLeanModifier child of the skeleton lerps the
# spine-bone z-rotation toward the new target each modification frame.
func set_torso_lean_only(direction: int) -> void:
	var clamped: int = clampi(direction, -1, 1)
	if clamped == _torso_lean_direction:
		return
	_torso_lean_direction = clamped


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


# Push the current lean direction to the modifier. Skipped (target = 0)
# during clips that own the upper body (INTERACT_* / DIE / RECOVER) so the
# punch / knockback / get-up poses aren't pre-tilted by leftover lean.
# The modifier itself owns the lerp + the actual bone pose write — see
# torso_lean_modifier.gd.
func _drive_torso_lean() -> void:
	if _lean_modifier == null:
		return
	var owns_upper_body: bool = (
		_state == MotionState.INTERACT_LEFT
		or _state == MotionState.INTERACT_RIGHT
		or _state == MotionState.DIE
		or _state == MotionState.RECOVER
	)
	var direction: int = 0 if owns_upper_body else _torso_lean_direction
	_lean_modifier.set_target_lean(direction)


# Build a TorsoLeanModifier and parent it to the resolved Skeleton3D.
# Tunables on this node's exports are forwarded once so the modifier can
# stay self-contained (it owns the lerp). Scenes that need to override per-
# instance (NPC bone name, Pawn lean amount) set the values on this node;
# the modifier reads them here.
func _install_lean_modifier() -> void:
	if skeleton == null:
		push_warning("[torso-lean] CharacterVisual on '%s' has no skeleton — modifier not installed." % name)
		return
	_lean_modifier = TorsoLeanModifier.new()
	_lean_modifier.name = "TorsoLeanModifier"
	_lean_modifier.spine_bone_name = spine_bone_name
	_lean_modifier.lean_amount = torso_lean_amount
	_lean_modifier.lean_speed = torso_lean_speed
	_lean_modifier.min_lean_radians = min_lean_radians
	_lean_modifier.ignore_time_scale = lean_ignore_time_scale
	skeleton.add_child(_lean_modifier)


# Return the state name used in the blend tree.
func _get_state_name(state: int) -> String:
	var state_name: String = STATE_NAMES.get(state, "walk")
	return state_name


# Return the animation clip name for a state.
func _get_animation_name(state: int) -> String:
	return ANIMATION_NAMES.get(state, "Walk_Loop RT")
