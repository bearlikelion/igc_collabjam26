class_name TorsoLeanModifier
extends SkeletonModifier3D

# Animation-independent torso lean. Runs as a SkeletonModifier3D so its bone
# pose write executes AFTER the AnimationTree updates the skeleton each frame
# and BEFORE world transforms commit — pose mutations survive the AnimationTree
# clobber that bites a naive `_process` write.
#
# Composes multiplicatively on top of whatever clip is playing:
#   set_bone_pose_rotation(idx, animated_pose * Quaternion(z, lean_radians))
# The walk/sprint clips' spine swing is preserved; the lean rides on top.
#
# Spine-bone name is data-driven: this project ships two rig families with
# different naming. Default fits the NPC1 Rigify rig used by player +
# CharacterVisual.tscn; the Mixamo-style NPCs override to "Chest".
#
# Usage: CharacterVisual creates one of these as a child of its Skeleton3D in
# _ready() and writes intent via set_target_lean(direction). Direction is
# -1/0/+1; this multiplies by lean_amount to produce the target radians.

## Bone name on the skeleton to apply the lean rotation to. Two families ship:
##   - NPC1 Rigify (mNPC1 / fNPC1 / player Pawn): "DEF-spine002"
##   - Mixamo-style (Doctor / Hoodie / Salaryman / Redhead / Elderly): "Chest"
## Resolved once at _ready via Skeleton3D.find_bone(); cached as int. Missing
## bone disables the modifier with a push_warning rather than crashing.
@export var spine_bone_name: String = "DEF-spine002"

## Peak lean angle in radians applied at direction = ±1. Pivot at the spine
## reads stronger per-radian than the old whole-rig pivot at the feet — start
## around 0.30 rad (~17°) for NPCs, ~0.45 rad (~26°) for the player.
@export var lean_amount: float = 0.30

## Lerp rate (rad/s-ish). Higher = snappier. 8.0 reaches ~95% of target in
## ~0.4s at 60fps.
@export var lean_speed: float = 8.0

## When true, lean ignores Engine.time_scale so it stays snappy during
## bullet-time. Set false on NPC scenes so their lean feels slow and dramatic
## while the player's bullet-time is engaged.
@export var ignore_time_scale: bool = true

## Minimum visible lean (radians) when direction is non-zero. On commit, the
## current lean is snapped to at least this magnitude so micro-leans can't
## read as neutral — left/center/right stay unambiguously distinct. Center
## (direction == 0) ignores the floor and lerps smoothly back to upright.
## Clamped to lean_amount internally so a mistuning where floor > amount
## doesn't produce a snap-then-drop. ~0.10 rad ≈ 5.7°.
@export var min_lean_radians: float = 0.10

## When true, prints a [torso-lean] line on bone resolve and on disable.
@export var debug_log: bool = false

var target_lean_radians: float = 0.0

var _current_lean_radians: float = 0.0
var _bone_idx: int = -1
var _skeleton: Skeleton3D


func _ready() -> void:
	_skeleton = get_skeleton()
	if _skeleton == null:
		push_warning("[torso-lean] no Skeleton3D parent — modifier disabled.")
		active = false
		return
	_bone_idx = _skeleton.find_bone(spine_bone_name)
	if _bone_idx < 0:
		push_warning("[torso-lean] bone '%s' not found on '%s' — modifier disabled." % [
			spine_bone_name, _skeleton.name,
		])
		active = false
		return
	if debug_log:
		print("[torso-lean] resolved bone '%s' → idx=%d on '%s'" % [
			spine_bone_name, _bone_idx, _skeleton.name,
		])


# Brain → Pawn → CharacterVisual → here. Direction is clamped to -1/0/+1 and
# multiplied by lean_amount to produce target radians. Always succeeds — this
# only writes intent; the lerp drives the actual pose write each modification
# frame.
func set_target_lean(direction: int) -> void:
	var clamped: int = clampi(direction, -1, 1)
	target_lean_radians = lean_amount * float(clamped)


func _process_modification() -> void:
	if _bone_idx < 0 or _skeleton == null:
		return
	var delta: float = get_process_delta_time()
	var effective_delta: float = delta
	if ignore_time_scale:
		effective_delta = delta / maxf(Engine.time_scale, 0.01)
	var weight: float = clampf(lean_speed * effective_delta, 0.0, 1.0)
	_current_lean_radians = lerpf(_current_lean_radians, target_lean_radians, weight)
	if absf(_current_lean_radians) < 0.001 and is_zero_approx(target_lean_radians):
		_current_lean_radians = 0.0
	# Telegraph floor: when committed to a non-zero direction, snap the current
	# lean to at least min_lean_radians on the target side so micro-leans can't
	# linger in the under-floor "is it leaning?" range. Release path (target
	# == 0) bypasses this and lerps smoothly back to upright.
	if not is_zero_approx(target_lean_radians):
		var effective_floor: float = minf(min_lean_radians, lean_amount)
		var target_sign: float = signf(target_lean_radians)
		var current_sign: float = signf(_current_lean_radians)
		if current_sign != target_sign or absf(_current_lean_radians) < effective_floor:
			_current_lean_radians = target_sign * effective_floor
	# Compose: animated pose * local-space z-rotation. Reading the post-
	# AnimationTree pose this frame and post-multiplying applies the lean in
	# the bone's local frame, so the chest follows whatever the clip is doing
	# rather than fighting it.
	var animated: Quaternion = _skeleton.get_bone_pose_rotation(_bone_idx)
	var leaned: Quaternion = animated * Quaternion(Vector3(0.0, 0.0, 1.0), _current_lean_radians)
	_skeleton.set_bone_pose_rotation(_bone_idx, leaned)
