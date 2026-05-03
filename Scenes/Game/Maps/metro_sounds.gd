class_name MetroSounds
extends AudioStreamPlayer

func _ready() -> void:
	finished.connect(_on_sound_finished)


func _on_sound_finished() -> void:
	play()
