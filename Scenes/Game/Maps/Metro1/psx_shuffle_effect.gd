class_name PSXShuffleEffect
extends MeshInstance3D

## Focus distance when shuffle begins — far, so the world looks sharp initially.
@export var dof_focus_start: float = 30.0
## Focus distance to lerp toward during the shuffle — pulls focus tight.
@export var dof_focus_target: float = 1.5
## How fast focus distance lerps toward target (units per second).
@export var dof_focus_speed: float = 18.0
## Vignette strength to lerp toward during a shuffle.
@export var vignette_shuffle: float = 1.4
## Vignette spikes to this multiplier * vignette_shuffle in the final stretch
## to signal the player must commit. Higher = more dramatic.
@export var vignette_spike_multiplier: float = 2.0
## How fast vignette lerps toward its target (units per second).
@export var vignette_speed: float = 4.0
## Progress threshold at which the vignette spike begins. 0.8 = last 20%.
@export_range(0.5, 0.95, 0.05) var vignette_spike_at: float = 0.8

var _material: ShaderMaterial
var _default_vignette: float
var _default_focus: float
var _in_shuffle: bool = false
var _current_focus: float
var _current_vignette: float
var _target_vignette: float
var _shuffle_deadline_msec: int = 0
var _player: Pawn


func _ready() -> void:
	_material = get_active_material(0) as ShaderMaterial
	if _material == null:
		push_error("PSXShuffleEffect: no ShaderMaterial on surface 0")
		return
	_default_vignette = _material.get_shader_parameter("vignette_strength")
	_default_focus = _material.get_shader_parameter("dof_focus_distance")
	_current_focus = _default_focus
	_current_vignette = _default_vignette
	_target_vignette = _default_vignette
	_player = get_tree().get_first_node_in_group("player") as Pawn
	if _player == null:
		push_error("PSXShuffleEffect: no Pawn in group 'player'")
		return
	_player.shuffle_began.connect(_on_shuffle_began)
	_player.shuffle_resolved.connect(_on_shuffle_resolved)


func _process(delta: float) -> void:
	if _material == null:
		return
	if _in_shuffle:
		var progress: float = _get_shuffle_progress()
		# DOF: pull focus tighter in the last 20% for deadline tension.
		# At the panic peak, focus snaps to 0.5m — very close blur.
		var dof_target: float = dof_focus_target
		if progress > 0.8:
			var late_t: float = (progress - 0.8) / 0.2
			dof_target = lerpf(dof_focus_target, 0.5, late_t)
		_current_focus = move_toward(_current_focus, dof_target, dof_focus_speed * delta)
		_material.set_shader_parameter("dof_focus_distance", _current_focus)

		# Vignette: scale with progress toward the deadline, then spike sharply
		# at `vignette_spike_at` to signal the player must commit.
		if progress < vignette_spike_at:
			# Smooth ramp from default up to shuffle strength.
			var ramp_t: float = progress / vignette_spike_at
			_target_vignette = lerpf(_default_vignette, vignette_shuffle, ramp_t)
		else:
			# Dramatic spike at deadline — fast converge toward spike target.
			var spike_t: float = (progress - vignette_spike_at) / (1.0 - vignette_spike_at)
			var spike_target: float = vignette_shuffle * vignette_spike_multiplier
			_target_vignette = lerpf(vignette_shuffle, spike_target, spike_t)

	if _current_vignette != _target_vignette:
		_current_vignette = move_toward(_current_vignette, _target_vignette, vignette_speed * delta)
		_material.set_shader_parameter("vignette_strength", _current_vignette)


# Compute shuffle progress (0.0–1.0) from the stored wall-clock deadline.
# Queries the dynamic choice time from Pawn (which reads MetroMovement) so
# any per-scene export override is automatically reflected.
func _get_shuffle_progress() -> float:
	if _shuffle_deadline_msec <= 0:
		return 0.0
	var remaining: float = float(maxi(_shuffle_deadline_msec - Time.get_ticks_msec(), 0))
	var choice_time: float = _player._get_shuffle_choice_time() if _player != null else 2.5
	var total_msec: float = choice_time * 1000.0
	return clampf(1.0 - remaining / total_msec, 0.0, 1.0)


func _on_shuffle_began(_other: Pawn, _telegraph: int, deadline_msec: int) -> void:
	if _material == null:
		return
	_in_shuffle = true
	_shuffle_deadline_msec = deadline_msec
	_current_focus = dof_focus_start
	_material.set_shader_parameter("dof_enabled", true)
	_material.set_shader_parameter("dof_focus_distance", _current_focus)
	_target_vignette = vignette_shuffle


func _on_shuffle_resolved(_succeeded: bool, _direction: int) -> void:
	if _material == null:
		return
	_in_shuffle = false
	_shuffle_deadline_msec = 0
	_material.set_shader_parameter("dof_enabled", false)
	_material.set_shader_parameter("dof_focus_distance", _default_focus)
	_target_vignette = _default_vignette
