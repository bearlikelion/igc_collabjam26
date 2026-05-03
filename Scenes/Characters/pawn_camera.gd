@tool
class_name PawnCamera
extends SpringArm3D

# Camera rig for Pawn. Wraps a SpringArm3D + Camera3D.
# First-person = spring_length 0, character model hidden by PlayerBrain.
# Third-person = spring_length = third_person_distance.
#
# Mouse pitch is applied by the owning Brain (PlayerBrain in current setup);
# this rig only exposes offsets and mode switching.

enum Mode { FIRST_PERSON, THIRD_PERSON }

const PITCH_LIMIT_DEG: float = 89.0

@export var invert_mouse_y: bool = false
@export var third_person_distance: float = 2.0

signal mode_changed(mode: int)

var _headbob_offset: float = 0.0

@onready var camera: Camera3D = _find_camera()


# Locate the Camera3D this rig drives. Searches children and grandchildren.
func _find_camera() -> Camera3D:
	for child: Node in get_children():
		if child is Camera3D:
			return child as Camera3D
		for grandchild: Node in child.get_children():
			if grandchild is Camera3D:
				return grandchild as Camera3D
	return null


# Apply a vertical bob offset to the child Camera3D.
func set_headbob_offset(offset: float) -> void:
	_headbob_offset = offset
	if camera != null:
		camera.position.y = _headbob_offset


# Switch between first-person (spring_length 0) and third-person distances.
func apply_mode(mode: int) -> void:
	match mode:
		Mode.FIRST_PERSON:
			spring_length = 0.0
		Mode.THIRD_PERSON:
			spring_length = third_person_distance
	mode_changed.emit(mode)
