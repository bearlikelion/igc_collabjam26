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
## How fast vignette lerps toward its target (units per second).
@export var vignette_speed: float = 4.0

var _material: ShaderMaterial
var _default_vignette: float
var _default_focus: float
var _in_shuffle: bool = false
var _current_focus: float
var _current_vignette: float
var _target_vignette: float


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
	var player: Pawn = get_tree().get_first_node_in_group("player") as Pawn
	if player == null:
		push_error("PSXShuffleEffect: no Pawn in group 'player'")
		return
	player.shuffle_began.connect(_on_shuffle_began)
	player.shuffle_resolved.connect(_on_shuffle_resolved)


func _process(delta: float) -> void:
	if _material == null:
		return
	if _in_shuffle:
		_current_focus = move_toward(_current_focus, dof_focus_target, dof_focus_speed * delta)
		_material.set_shader_parameter("dof_focus_distance", _current_focus)
	if _current_vignette != _target_vignette:
		_current_vignette = move_toward(_current_vignette, _target_vignette, vignette_speed * delta)
		_material.set_shader_parameter("vignette_strength", _current_vignette)


func _on_shuffle_began(_other: Pawn, _telegraph: int, _deadline_msec: int) -> void:
	if _material == null:
		return
	_in_shuffle = true
	_current_focus = dof_focus_start
	_material.set_shader_parameter("dof_enabled", true)
	_material.set_shader_parameter("dof_focus_distance", _current_focus)
	_target_vignette = vignette_shuffle


func _on_shuffle_resolved(_succeeded: bool, _direction: int) -> void:
	if _material == null:
		return
	_in_shuffle = false
	_material.set_shader_parameter("dof_enabled", false)
	_material.set_shader_parameter("dof_focus_distance", _default_focus)
	_target_vignette = _default_vignette
