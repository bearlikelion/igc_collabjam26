extends Camera3D

@onready var player: Pawn = get_tree().get_first_node_in_group('player')
@onready var animation_player: AnimationPlayer = $AnimationPlayer

func _ready() -> void:
	player.goal_reached.connect(_on_goal_reached)


func _on_goal_reached() -> void:
	await get_tree().create_timer(0.25).timeout
	current = true
	animation_player.play('train_departure')
