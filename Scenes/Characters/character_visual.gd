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
@export var torso_lean_amount: float = 0.15
@export var torso_lean_speed: float = 3.0
@export var skeleton: Skeleton3D
@export var animation_player: AnimationPlayer

@onready var animation_tree: AnimationTree = $AnimationTree
@onready var model_root: Node3D = $ModelRoot

var _playback: AnimationNodeStateMachinePlayback
var _state: int = MotionState.WALK
var _torso_bone_index: int = -1
var _current_torso_lean: float = 0.0
var _state_lock_time: float = 0.0
var _locked_state: int = -1
var _torso_lean_direction: int = 0


# Build the reusable animation state machine after child nodes are ready.
func _ready() -> void:
	process_priority = 100
	if skeleton != null:
		_torso_bone_index = skeleton.find_bone("Hips")
	if _torso_bone_index < 0:
		push_warning("CharacterVisual could not find torso bone for lean.")
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


# Play the normal forward walking state.
func play_walk() -> void:
	if _is_recovery_state_locked():
		return
	_torso_lean_direction = 0
	_travel(MotionState.WALK)


# Play the faster locomotion state.
func play_sprint() -> void:
	if _is_recovery_state_locked():
		return
	_torso_lean_direction = 0
	_travel(MotionState.SPRINT)


# Play a left-side interaction dodge/shuffle animation.
func play_interact_left() -> void:
	if _is_recovery_state_locked():
		return
	_torso_lean_direction = -1
	_travel(MotionState.INTERACT_LEFT)
	_lock_state_for_animation(MotionState.INTERACT_LEFT)


# Play a right-side interaction dodge/shuffle animation.
func play_interact_right() -> void:
	if _is_recovery_state_locked():
		return
	_torso_lean_direction = 1
	_travel(MotionState.INTERACT_RIGHT)
	_lock_state_for_animation(MotionState.INTERACT_RIGHT)


# Set just the torso lean direction without changing animation state. Used by
# AI brains to broadcast a pre-shuffle tell during run-up — body keeps walking
# while the spine angles toward the side the AI plans to dodge.
func set_torso_lean_only(direction: int) -> void:
	_torso_lean_direction = clampi(direction, -1, 1)


# Play the death animation.
func play_die() -> void:
	if _state == MotionState.DIE and _is_recovery_state_locked():
		return
	_torso_lean_direction = 0
	_travel(MotionState.DIE)
	_lock_state_for_animation(MotionState.DIE)


# Play the collision recovery animation.
func play_recover() -> void:
	if _is_recovery_state_locked():
		return
	_torso_lean_direction = 0
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
	print("Set walk speed to %s" % walk_speed)


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


# Apply a directional torso lean for side interactions. The lerp uses
# wall-clock-equivalent delta (re-scaled out of Engine.time_scale) so the
# lean still snaps in visible time during bullet-time shuffles. Without this,
# Engine.time_scale = 0.2 stretches the lerp 5× and the lean barely moves
# before the shuffle resolves.
func _update_torso_lean(delta: float) -> void:
	if skeleton == null or _torso_bone_index < 0:
		return

	var target_lean: float = torso_lean_amount * float(_torso_lean_direction)

	var wall_delta: float = delta / maxf(Engine.time_scale, 0.01)
	var weight: float = clamp(torso_lean_speed * wall_delta, 0.0, 1.0)
	_current_torso_lean = lerp(_current_torso_lean, target_lean, weight)
	if abs(_current_torso_lean) < 0.001 and is_zero_approx(target_lean):
		_current_torso_lean = 0.0

	var pose_rotation: Quaternion = skeleton.get_bone_pose_rotation(_torso_bone_index)
	var pose_euler: Vector3 = pose_rotation.get_euler()
	pose_euler.z = _current_torso_lean
	skeleton.set_bone_pose_rotation(_torso_bone_index, Quaternion.from_euler(pose_euler))


# Return the state name used in the blend tree.
func _get_state_name(state: int) -> String:
	var state_name: String = STATE_NAMES.get(state, "walk")
	return state_name


# Return the animation clip name for a state.
func _get_animation_name(state: int) -> String:
	return ANIMATION_NAMES.get(state, "Walk_Loop RT")
