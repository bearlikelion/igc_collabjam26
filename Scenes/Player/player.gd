class_name Player
extends SUCC

# Auto-runner. The level script drives position directly via parametric movement
# along path segments. Lane = perpendicular offset; forward = distance along segment.
# Player.gd just handles input and exposes _current_lane.

const LANE_COUNT: int = 3

@export var start_speed: float = 2.0
@export var max_speed: float = 6.0
## Time in seconds to accelerate from start_speed to max_speed.
@export var acceleration_time: float = 5.0
@export var player_model: Node3D

signal lane_changed

var _current_lane: int = 1
var run_speed: float = 0.0

@onready var navigation_agent: NavigationAgent3D = $NavigationAgent3D


func _ready() -> void:
	super()
	run_speed = start_speed
	if camera_mode == CameraMode.FIRST_PERSON:
		player_model.hide()


func _unhandled_input(event: InputEvent) -> void:
	if _can_look() and camera_rig and event is InputEventMouseMotion:
		_handle_pitch_only(event as InputEventMouseMotion)
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
				else Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	# Movement is driven externally by the level script via set_position.
	# Here we only handle input and accelerate run_speed toward max_speed.
	if game_state == GameState.DISABLED or not _can_move():
		return
	_handle_lane_input()
	if run_speed < max_speed and acceleration_time > 0.0:
		var rate: float = (max_speed - start_speed) / acceleration_time
		run_speed = min(max_speed, run_speed + rate * delta)


func _handle_lane_input() -> void:
	if Input.is_action_just_pressed("left") and _current_lane > 0:
		_current_lane -= 1
		lane_changed.emit()
		print("LANE CHANGE LEFT -> lane %s" % _current_lane)
	elif Input.is_action_just_pressed("right") and _current_lane < LANE_COUNT - 1:
		_current_lane += 1
		lane_changed.emit()
		print("LANE CHANGE RIGHT -> lane %s" % _current_lane)


func _gather_movement_input() -> void:
	move_dir = Vector3.ZERO
	move_input = Vector2.ZERO
	wish_sprint = false
	wish_jump = false
	wish_crouch = false


func _handle_pitch_only(event: InputEventMouseMotion) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	var relative: Vector2 = event.relative
	relative *= config.mouse_sensitivity * deg_to_rad(config.degrees_per_unit)

	var invert: float = -1.0 if camera_rig.invert_mouse_y else 1.0
	camera_rig.rotate_object_local(Vector3.RIGHT, invert * -relative.y)
	camera_rig.rotation.x = clamp(
		camera_rig.rotation.x,
		deg_to_rad(-SUCCCamera.PITCH_LIMIT_DEG),
		deg_to_rad(SUCCCamera.PITCH_LIMIT_DEG)
	)
	camera_rig.orthonormalize()
