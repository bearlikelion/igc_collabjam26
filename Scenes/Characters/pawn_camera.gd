@tool
class_name PawnCamera
extends SpringArm3D

# Camera rig for Pawn. Wraps a SpringArm3D + Camera3D and owns all per-frame
# camera math: pitch input, headbob, lane-lean spring-damper, shuffle tilt.
# Pawn drives intent only (set_*, engage/disengage, apply_pitch_input); the
# rig observes via setters and runs its own _process.
#
# Tracking model (Stage 6+):
#   - One rig instance lives at level scene root, in group "player_camera".
#   - PlayerBrain resolves the rig at bind time, calls set_target(pawn),
#     and assigns it to pawn.camera_rig.
#   - The player Pawn carries a RemoteTransform3D child whose remote_path
#     points at this rig (update_position = true; rotation/scale = false).
#     The engine copies Pawn position to the rig every frame post-physics.
#   - This rig copies target_pawn.rotation.y manually at the top of _process
#     so yaw follows the Pawn's rail-following lerp without RemoteTransform3D
#     clobbering local pitch (X) and roll (Z).
#   - NPCs have no rig — every camera_rig check on Pawn short-circuits.
#
# First-person = spring_length 0, character model hidden by PlayerBrain at bind.
# Third-person = spring_length = third_person_distance (PlayerBrain flips to
# this in `on_knocked_down` so the player sees their body fall).
#
# Z-rotation has two modes:
#   - LANE_LEAN  (default): spring-damped roll toward held lane intent + tween
#                follow-through. Active outside shuffle/knockdown.
#   - SHUFFLE_TILT: lerp toward shuffle_camera_tilt_degrees * direction. Active
#                 when Pawn calls engage_shuffle_tilt(...) — typically from
#                 shuffle entry through the end of knockdown recovery.

enum Mode { FIRST_PERSON, THIRD_PERSON }

const PITCH_LIMIT_DEG: float = 89.0


@export var invert_mouse_y: bool = false
@export var third_person_distance: float = 2.0

@export_group("Mouse")
@export var mouse_sensitivity: float = 3.0
## Source-engine scale: degrees of view rotation per mouse "unit". 0.022 = Source default.
@export var degrees_per_unit: float = 0.022

@export_group("Headbob")
@export var enable_headbob: bool = true
@export_range(0.0, 0.2, 0.001, "suffix:m") var headbob_amplitude: float = 0.025
@export_range(0.0, 6.0, 0.05, "suffix:steps/m") var headbob_steps_per_meter: float = 0.65
@export_range(0.0, 30.0, 0.1) var headbob_smoothing: float = 12.0

@export_group("Lane Lean")
@export_range(0.0, 25.0, 0.1, "suffix:deg") var lane_camera_tilt_degrees: float = 8.0
## Spring stiffness for the camera lean. Higher = snappier.
@export_range(1.0, 400.0, 1.0) var lane_camera_tilt_stiffness: float = 90.0
## Spring damping ratio. <1 underdamped, ==1 critical, >1 overdamped. ~0.45 = bouncy.
@export_range(0.0, 2.0, 0.01) var lane_camera_tilt_damping_ratio: float = 0.45

@export_group("Shuffle Camera Tilt")
@export_range(0.0, 25.0, 0.1, "suffix:deg") var shuffle_camera_tilt_degrees: float = 8.0
@export_range(0.0, 40.0, 0.1) var shuffle_camera_tilt_speed: float = 18.0

@export_group("Shuffle FOV")
## How many degrees to narrow FOV when a shuffle begins.
@export_range(0.0, 30.0, 0.1, "suffix:deg") var shuffle_fov_reduction: float = 6.0
## Speed at which FOV lerps to the shuffle target and back (degrees per second, wall-clock).
@export_range(0.1, 60.0, 0.1) var shuffle_fov_speed: float = 12.0


signal mode_changed(mode: int)


# Pawn this rig is currently tracking. Set by PlayerBrain at bind. Yaw is
# copied from this Pawn each _process tick; position comes via the
# RemoteTransform3D engine path.
var target_pawn: Pawn

# State
var _headbob_phase: float = 0.0
var _headbob_offset: float = 0.0
var _lane_lean_velocity: float = 0.0
var _lean_direction: int = 0
var _shuffle_tilt_direction: int = 0
var _shuffle_tilt_active: bool = false
var _fov_default: float = 0.0
var _fov_target: float = 0.0
var _speed: float = 0.0
# Tween snapshot used by lane-lean follow-through. Pawn calls
# set_tween_snapshot once per frame.
var _tween_active: bool = false
var _tween_from: float = 0.0
var _tween_target: float = 0.0
var _tween_progress: float = 0.0

# Shuffle progress (0.0 = just started, 1.0 = deadline imminent).
# Set by Pawn._process each frame. Used for dynamic tilt/FOV escalation.
var _shuffle_progress: float = 0.0


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


func _ready() -> void:
	if camera != null:
		_fov_default = camera.fov
		_fov_target = camera.fov


# Per-frame camera math. @tool so editor-only — guard explicitly.
func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	# Track the active Pawn's yaw. Position is copied via RemoteTransform3D
	# from the player Pawn (engine-managed); rotation isn't copied there so
	# our pitch (X) and roll (Z) stay intact.
	if target_pawn != null:
		rotation.y = target_pawn.rotation.y
	_update_headbob(delta)
	_update_shuffle_fov(delta)
	if _shuffle_tilt_active:
		_update_shuffle_tilt(delta)
		# Drain lane-lean velocity so the spring doesn't pop when we
		# disengage shuffle tilt back to lane lean.
		_lane_lean_velocity = 0.0
	else:
		_update_lane_lean(delta)


# --- Tracking + activation + mode -----------------------------------------

# Bind this rig to a Pawn. Snaps yaw immediately so the first frame doesn't
# show a stale orientation. Position is driven by the player Pawn's
# RemoteTransform3D child (engine push during physics), so we don't snap it
# here — it gets the right value on the first physics tick post-bind.
# PlayerBrain calls this on bind.
func set_target(pawn: Pawn) -> void:
	target_pawn = pawn
	if pawn == null:
		return
	rotation.y = pawn.rotation.y


# Claim this rig's Camera3D as the active view.
func set_active(active: bool) -> void:
	if not active or camera == null:
		return
	camera.current = true


# Switch between first-person (spring_length 0) and third-person distances.
func apply_mode(mode: int) -> void:
	match mode:
		Mode.FIRST_PERSON:
			spring_length = 0.0
		Mode.THIRD_PERSON:
			spring_length = third_person_distance
	mode_changed.emit(mode)


# --- Per-frame intents ----------------------------------------------------

# Effective forward speed in m/s. Pawn passes 0 when not RUNNING so headbob
# settles to neutral.
func set_speed(speed: float) -> void:
	_speed = speed


# Held lane intent (-1, 0, +1). Lane-lean spring rolls toward this direction
# while idle; otherwise the tween-progress follow-through takes over.
func set_lean_direction(direction: int) -> void:
	_lean_direction = direction


# Snapshot of Pawn's lane tween — used by lane-lean follow-through. Called
# once per frame from Pawn._process.
func set_tween_snapshot(active: bool, from_lane: float, to_lane: float, progress: float) -> void:
	_tween_active = active
	_tween_from = from_lane
	_tween_target = to_lane
	_tween_progress = progress


# Set shuffle deadline progress (0.0–1.0) for dynamic tilt/FOV escalation.
# Called once per frame from Pawn._process during SHUFFLING.
func set_shuffle_progress(progress: float) -> void:
	_shuffle_progress = progress


# Apply mouse pitch input. Yaw is owned by MetroMovement's rail-following
# lerp; this handles pitch (X rotation) only.
func apply_pitch_input(relative_y: float) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	var scaled: float = relative_y * mouse_sensitivity * deg_to_rad(degrees_per_unit)
	var invert: float = -1.0 if invert_mouse_y else 1.0
	rotate_object_local(Vector3.RIGHT, invert * -scaled)
	rotation.x = clamp(
		rotation.x,
		deg_to_rad(-PITCH_LIMIT_DEG),
		deg_to_rad(PITCH_LIMIT_DEG)
	)
	orthonormalize()


# --- Shuffle tilt mode toggle ---------------------------------------------

# Engage shuffle tilt — overrides lane lean for rotation.z. Rig lerps
# rotation.z toward shuffle_camera_tilt_degrees * direction. Pawn calls this
# on shuffle entry, telegraph change, and knockdown enter (with direction=0
# during knockdown so the camera rolls back to upright as the player falls).
func engage_shuffle_tilt(direction: int) -> void:
	_shuffle_tilt_active = true
	_shuffle_tilt_direction = direction
	_shuffle_progress = 0.0
	_fov_target = _fov_default - shuffle_fov_reduction


# Hand rotation.z back to the lane-lean spring.
func disengage_shuffle_tilt() -> void:
	_shuffle_tilt_active = false
	_shuffle_tilt_direction = 0
	_shuffle_progress = 0.0
	_fov_target = _fov_default


# --- Internal --------------------------------------------------------------

func _update_headbob(delta: float) -> void:
	var target_offset: float = 0.0
	if enable_headbob and _speed > 0.01:
		_headbob_phase = fmod(_headbob_phase + _speed * headbob_steps_per_meter * TAU * delta, TAU)
		target_offset = sin(_headbob_phase) * headbob_amplitude
	var t: float = 1.0 if headbob_smoothing <= 0.0 else clamp(headbob_smoothing * delta, 0.0, 1.0)
	_headbob_offset = lerp(_headbob_offset, target_offset, t)
	if abs(_headbob_offset) < 0.0001 and is_zero_approx(target_offset):
		_headbob_offset = 0.0
	if camera != null:
		camera.position.y = _headbob_offset


# Lerp camera FOV toward its target. Wall-clock aware so the zoom feels the
# same speed regardless of bullet-time. During active shuffle the target is
# dynamic — ramping from neutral to full reduction as deadline approaches,
# with an extra spike in the final 15% for tension.
func _update_shuffle_fov(delta: float) -> void:
	if camera == null:
		return
	var fov_delta: float = delta / maxf(Engine.time_scale, 0.001)
	if _shuffle_tilt_active:
		# Dynamic FOV target during shuffle: ramp reduction by progress.
		var reduction: float = shuffle_fov_reduction * clampf(_shuffle_progress * 1.2, 0.0, 1.0)
		# Extra 2° spike in the last 15% for deadline tension.
		if _shuffle_progress > 0.85:
			var sp: float = (_shuffle_progress - 0.85) / 0.15
			reduction += 2.0 * sp
		var dynamic_target: float = _fov_default - reduction
		camera.fov = move_toward(camera.fov, dynamic_target, shuffle_fov_speed * fov_delta)
	elif camera.fov != _fov_default:
		camera.fov = move_toward(camera.fov, _fov_default, shuffle_fov_speed * fov_delta)


# Lerp rotation.z toward the shuffle-tilt target. Time-scale aware so the
# tilt animates at wall-clock speed during bullet-time. The target tilt is
# multiplied by a dynamic tension ramp: gentle early, spiking near deadline.
func _update_shuffle_tilt(delta: float) -> void:
	var tilt_multiplier: float = _get_shuffle_tilt_multiplier()
	var target_tilt: float = -deg_to_rad(shuffle_camera_tilt_degrees) * float(_shuffle_tilt_direction) * tilt_multiplier
	var tilt_delta: float = delta / maxf(Engine.time_scale, 0.001)
	var weight: float = 1.0 if shuffle_camera_tilt_speed <= 0.0 \
			else clamp(shuffle_camera_tilt_speed * tilt_delta, 0.0, 1.0)
	rotation.z = lerp_angle(rotation.z, target_tilt, weight)
	if abs(rotation.z) < 0.001 and is_zero_approx(target_tilt):
		rotation.z = 0.0


# Compute the dynamic tilt multiplier based on shuffle progress.
# Early (0–0.3): ramp from 0.25× to 1.0× — gentle lean-in.
# Mid (0.3–0.75): hold at 1.0× — standard lean.
# Late (0.75–1.0): spike to 1.6× — tension peak before resolution.
func _get_shuffle_tilt_multiplier() -> float:
	if _shuffle_progress < 0.3:
		return lerpf(0.25, 1.0, _shuffle_progress / 0.3)
	elif _shuffle_progress < 0.75:
		return 1.0
	else:
		var late_progress: float = (_shuffle_progress - 0.75) / 0.25
		return lerpf(1.0, 1.6, late_progress)


# Roll the camera toward the held lane intent, then decay through the body
# tween via 1 - sqrt(t) so the lean follows through and uprights as the body
# settles. Spring-damper so it overshoots and bounces when underdamped.
func _update_lane_lean(delta: float) -> void:
	var target_tilt: float = 0.0
	if _lean_direction != 0:
		target_tilt = -deg_to_rad(lane_camera_tilt_degrees) * float(_lean_direction)
	elif _tween_active:
		var diff: float = _tween_target - _tween_from
		var travel_dir: int = 1 if diff > 0.0 else (-1 if diff < 0.0 else 0)
		if travel_dir != 0:
			var follow: float = 1.0 - sqrt(_tween_progress)
			target_tilt = -deg_to_rad(lane_camera_tilt_degrees) * float(travel_dir) * follow
	var current: float = rotation.z
	var damping: float = 2.0 * sqrt(lane_camera_tilt_stiffness) * lane_camera_tilt_damping_ratio
	var acceleration: float = lane_camera_tilt_stiffness * (target_tilt - current) - damping * _lane_lean_velocity
	_lane_lean_velocity += acceleration * delta
	var next: float = current + _lane_lean_velocity * delta
	if absf(_lane_lean_velocity) < 0.01 and absf(next - target_tilt) < 0.001:
		next = target_tilt
		_lane_lean_velocity = 0.0
	rotation.z = next
