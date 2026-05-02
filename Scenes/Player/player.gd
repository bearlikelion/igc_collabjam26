class_name Player
extends SUCC

# Auto-runner player controller. Moves forward automatically at a fixed speed,
# left/right inputs snap instantly between 3 lanes. Mouse look is pitch-only;
# yaw is locked so the camera always faces straight ahead.

const LANE_COUNT: int = 3
const LANE_OFFSETS: Array[float] = [-2.0, 0.0, 2.0]

@export var run_speed: float = 10.0

var _current_lane: int = 1
var _target_x: float = 0.0


func _ready() -> void:
	super()
	_target_x = LANE_OFFSETS[_current_lane]


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or not is_multiplayer_authority():
		return
	if _can_look() and camera_rig and event is InputEventMouseMotion:
		_handle_pitch_only(event as InputEventMouseMotion)
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
				else Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or not is_multiplayer_authority():
		return
	if game_state == GameState.DISABLED or not _can_move():
		velocity = Vector3.ZERO
		move_and_slide()
		return

	_handle_lane_input()
	_apply_gravity(delta)

	# Lateral: move toward target lane at run_speed, stop exactly on arrival.
	var diff: float = _target_x - global_position.x
	var step: float = run_speed * delta
	if abs(diff) <= step:
		velocity.x = diff / delta if delta > 0.0 else 0.0
	else:
		velocity.x = sign(diff) * run_speed

	# Forward speed is constant and set last so nothing can change it.
	velocity.z = -run_speed

	move_and_slide()

	# Re-lock forward speed after move_and_slide in case a collision deflected it.
	velocity.z = -run_speed
	velocity.x = clamp(velocity.x, -run_speed, run_speed)

	_update_movement_state()


func _handle_lane_input() -> void:
	if Input.is_action_just_pressed("left"):
		_current_lane = max(0, _current_lane - 1)
		_target_x = LANE_OFFSETS[_current_lane]
	elif Input.is_action_just_pressed("right"):
		_current_lane = min(LANE_COUNT - 1, _current_lane + 1)
		_target_x = LANE_OFFSETS[_current_lane]


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
