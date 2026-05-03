class_name CharacterVisual
extends Node3D

enum MotionState { WALK, SPRINT, INTERACT_LEFT, INTERACT_RIGHT, DIE, RECOVER }

const ANIMATION_NAMES: Dictionary[int, String] = {
	MotionState.WALK: "walk",
	MotionState.SPRINT: "sprint",
	MotionState.INTERACT_LEFT: "interact-left",
	MotionState.INTERACT_RIGHT: "interact-right",
	MotionState.DIE: "die",
	MotionState.RECOVER: "recover",
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
@export var torso_lean_speed: float = 12.0
@export var skeleton: Skeleton3D

@onready var animation_player: AnimationPlayer = $ModelRoot/suit_male/AnimationPlayer
@onready var animation_tree: AnimationTree = $AnimationTree
@onready var model_root: Node3D = $ModelRoot

var _playback: AnimationNodeStateMachinePlayback
var _state: int = MotionState.WALK
var _torso_bone_index: int = -1
var _current_torso_lean: float = 0.0
var _state_lock_time: float = 0.0


# Build the reusable animation state machine after child nodes are ready.
func _ready() -> void:
	_torso_bone_index = skeleton.find_bone("torso")
	_configure_animation_tree()
	play_walk()


# Blend the torso lean after animation playback updates the skeleton.
func _process(delta: float) -> void:
	_state_lock_time = maxf(0.0, _state_lock_time - delta)
	_update_torso_lean(delta)


# Set locomotion animation from current movement speed.
func set_move_speed(speed: float) -> void:
	if _state_lock_time > 0.0 or _state == MotionState.DIE or _state == MotionState.RECOVER:
		return
	if speed >= walk_speed_threshold:
		play_sprint()
	else:
		play_walk()


# Play the normal forward walking state.
func play_walk() -> void:
	_travel(MotionState.WALK)


# Play the faster locomotion state.
func play_sprint() -> void:
	_travel(MotionState.SPRINT)


# Play a left-side interaction dodge/shuffle animation.
func play_interact_left() -> void:
	_travel(MotionState.INTERACT_LEFT)
	_lock_state_for_animation(MotionState.INTERACT_LEFT)


# Play a right-side interaction dodge/shuffle animation.
func play_interact_right() -> void:
	_travel(MotionState.INTERACT_RIGHT)
	_lock_state_for_animation(MotionState.INTERACT_RIGHT)


# Play the death animation.
func play_die() -> void:
	_travel(MotionState.DIE)


# Play the collision recovery animation.
func play_recover() -> void:
	_travel(MotionState.RECOVER)


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
	var animation_name: String = _get_animation_name(state)
	if not animation_player.has_animation(animation_name):
		animation_name = "RESET"
	if _playback != null:
		_playback.travel(animation_name)
	elif animation_player.has_animation(animation_name):
		animation_player.play(animation_name)
	_state = state


# Prevent locomotion updates from immediately replacing a one-shot state.
func _lock_state_for_animation(state: int) -> void:
	var animation_name: String = _get_animation_name(state)
	if animation_player.has_animation(animation_name):
		_state_lock_time = animation_player.get_animation(animation_name).length


# Apply a directional torso lean for side interactions.
func _update_torso_lean(delta: float) -> void:
	if _torso_bone_index < 0:
		return

	var target_lean: float = 0.0
	if _state == MotionState.INTERACT_LEFT:
		target_lean = -torso_lean_amount
	elif _state == MotionState.INTERACT_RIGHT:
		target_lean = torso_lean_amount

	var weight: float = clamp(torso_lean_speed * delta, 0.0, 1.0)
	_current_torso_lean = lerp(_current_torso_lean, target_lean, weight)
	if abs(_current_torso_lean) < 0.001 and is_zero_approx(target_lean):
		_current_torso_lean = 0.0

	var pose_rotation: Quaternion = skeleton.get_bone_pose_rotation(_torso_bone_index)
	var pose_euler: Vector3 = pose_rotation.get_euler()
	pose_euler.z = _current_torso_lean
	skeleton.set_bone_pose_rotation(_torso_bone_index, Quaternion.from_euler(pose_euler))


# Return the state name used in the blend tree.
func _get_state_name(state: int) -> StringName:
	return StringName(_get_animation_name(state))


# Return the animation clip name for a state.
func _get_animation_name(state: int) -> String:
	return ANIMATION_NAMES.get(state, "walk")
