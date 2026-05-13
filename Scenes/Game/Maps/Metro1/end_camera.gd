extends Camera3D

# Now driven by the train's departure timer, not by the player reaching the
# rail end — the train decides when to leave; this camera just cuts in when
# it does. Win-vs-fail branching is handled inside Train (cinematic plays for
# both; fail path resets the level afterward).

func _ready() -> void:
	var train: Train = get_tree().get_first_node_in_group("train") as Train
	if train != null:
		train.departed.connect(_on_train_departed)


func _on_train_departed() -> void:
	current = true
