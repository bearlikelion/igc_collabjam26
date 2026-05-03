class_name Player
extends SUCC

# Auto-runner. The level script drives position directly via parametric movement
# along path segments. Lane = perpendicular offset; forward = distance along segment.
# Player.gd handles lane input, speed, and camera pitch.

const LANE_COUNT: int = 3

@export var start_speed: float = 2.0
@export var max_speed: float = 6.0
## Time in seconds to accelerate from start_speed to max_speed.
@export var acceleration_time: float = 5.0
@export var player_model: Node3D

@export_group("Headbob")
@export var enable_headbob: bool = true
@export_range(0.0, 0.2, 0.001, "suffix:m") var headbob_amplitude: float = 0.025
@export_range(0.0, 6.0, 0.05, "suffix:steps/m") var headbob_steps_per_meter: float = 0.65
@export_range(0.0, 30.0, 0.1) var headbob_smoothing: float = 12.0

signal lane_changed

var _current_lane: int = 1
var run_speed: float = 0.0
var _headbob_phase: float = 0.0
var _headbob_offset: float = 0.0


# Initialize speed and visual state.
func _ready() -> void:
	super()
	run_speed = start_speed
	if camera_mode == CameraMode.FIRST_PERSON and player_model != null:
		player_model.hide()


# Update camera effects after inherited camera smoothing.
func _process(delta: float) -> void:
	super(delta)
	_update_headbob(delta)


# Handle look and mouse capture input.
func _unhandled_input(event: InputEvent) -> void:
	if _can_look() and camera_rig and event is InputEventMouseMotion:
		_handle_pitch_only(event as InputEventMouseMotion)
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
				else Input.MOUSE_MODE_CAPTURED


# Update lane input and run speed.
func _physics_process(delta: float) -> void:
	# Movement is driven externally by the level script via set_position.
	# Here we only handle input and accelerate run_speed toward max_speed.
	if game_state == GameState.DISABLED or not _can_move():
		return
	_handle_lane_input()
	_update_run_speed(delta)


# Return the active lane index for external movement controllers.
func get_current_lane() -> int:
	return _current_lane


# Accelerate toward max speed.
func _update_run_speed(delta: float) -> void:
	if run_speed < max_speed and acceleration_time > 0.0:
		var rate: float = (max_speed - start_speed) / acceleration_time
		run_speed = min(max_speed, run_speed + rate * delta)


# Apply speed-scaled vertical camera headbob.
func _update_headbob(delta: float) -> void:
	if camera_rig == null:
		return

	var target_offset: float = 0.0
	if enable_headbob and game_state == GameState.ACTIVE and _can_move() and run_speed > 0.01:
		_headbob_phase = fmod(_headbob_phase + run_speed * headbob_steps_per_meter * TAU * delta, TAU)
		target_offset = sin(_headbob_phase) * headbob_amplitude

	var t: float = 1.0 if headbob_smoothing <= 0.0 else clamp(headbob_smoothing * delta, 0.0, 1.0)
	_headbob_offset = lerp(_headbob_offset, target_offset, t)
	if abs(_headbob_offset) < 0.0001 and is_zero_approx(target_offset):
		_headbob_offset = 0.0
	camera_rig.set_headbob_offset(_headbob_offset)


# Apply lane input.
func _handle_lane_input() -> void:
	if Input.is_action_just_pressed("left") and _current_lane > 0:
		_set_current_lane(_current_lane - 1)
	elif Input.is_action_just_pressed("right") and _current_lane < LANE_COUNT - 1:
		_set_current_lane(_current_lane + 1)


# Update the lane and notify listeners.
func _set_current_lane(next_lane: int) -> void:
	var clamped_lane: int = clampi(next_lane, 0, LANE_COUNT - 1)
	if clamped_lane == _current_lane:
		return
	_current_lane = clamped_lane
	lane_changed.emit()
	print("LANE CHANGE -> lane %s" % _current_lane)


# Disable inherited direct movement input.
func _gather_movement_input() -> void:
	move_dir = Vector3.ZERO
	move_input = Vector2.ZERO
	wish_sprint = false
	wish_jump = false
	wish_crouch = false


# Apply first-person pitch while external code drives translation.
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
