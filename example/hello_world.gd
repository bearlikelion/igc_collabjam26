extends TextureRect

@export var velocity := Vector2(200, 150)
@export var colors: Array[Color] = [
	Color(1, 0.341, 0.345, 1),
	Color(0.341, 1, 0.376, 1),
	Color(0.341, 0.573, 1, 1),
	Color(1, 0.878, 0.341, 1),
	Color(0.878, 0.341, 1, 1),
	Color(0.341, 1, 0.933, 1),
]
var color_index := 0

func _ready() -> void:
	await get_tree().process_frame
	pivot_offset = size / 2

func _bounce() -> void:
	color_index = (color_index + 1) % colors.size()
	var next_color: Color = colors[color_index]

	var tween := create_tween()
	tween.tween_method(
		func(c: Color) -> void: modulate = c,
		Color.WHITE, next_color, 0.1
	)


func _process(delta: float) -> void:
	var viewport_size := get_viewport_rect().size
	var label_size := size * scale
	var pos := position

	pos += velocity * delta

	var bounced_x := false
	var bounced_y := false

	if pos.x <= 0:
		pos.x = 0
		velocity.x = abs(velocity.x)
		bounced_x = true
	elif pos.x + label_size.x >= viewport_size.x:
		pos.x = viewport_size.x - label_size.x
		velocity.x = -abs(velocity.x)
		bounced_x = true

	if pos.y <= 0:
		pos.y = 0
		velocity.y = abs(velocity.y)
		bounced_y = true
	elif pos.y + label_size.y >= viewport_size.y:
		pos.y = viewport_size.y - label_size.y
		velocity.y = -abs(velocity.y)
		bounced_y = true

	if bounced_x or bounced_y:
		# prefer the axis that actually hit; corner = x wins
		_bounce()

	position = pos
