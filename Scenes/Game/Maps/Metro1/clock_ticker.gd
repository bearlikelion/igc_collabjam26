class_name ClockTicker
extends AudioStreamPlayer

# Drives this AudioStreamPlayer's pitch_scale from the Train's remaining
# departure time. Ramps from 1.0 (full time left) up to `max_pitch` (no time
# left) along a quadratic ease-in — pitch holds near 1.0 for the first half
# of the countdown, then accelerates hard in the back end so the time
# pressure reads when it matters.
#
# Multiplies through by `Engine.time_scale` every frame so the ticker slows
# in lockstep with the game during the subway shuffle's bullet-time
# (`Engine.time_scale = shuffle_bullet_time_scale`, default 0.2). Audio
# playback itself doesn't respect `Engine.time_scale` by default, so this
# is the bridge.
#
# Stops on Train.departed so the ticker doesn't bleed into the cinematic.

## Pitch ceiling reached as the countdown hits zero (before time_scale).
@export_range(1.0, 8.0, 0.1) var max_pitch: float = 3.0

var _train: Train


func _ready() -> void:
	# Deferred so the Train has a chance to run its own _ready (which adds it
	# to group "train") regardless of scene-tree iteration order.
	_resolve_train.call_deferred()


func _process(_delta: float) -> void:
	if _train == null or not playing:
		return
	var total: float = _train.departure_time
	if total <= 0.0:
		return
	var left: float = _train.get_time_left()
	var elapsed_fraction: float = clampf(1.0 - left / total, 0.0, 1.0)
	var eased: float = elapsed_fraction * elapsed_fraction
	# Clamp away from zero: pitch_scale of 0 is invalid on AudioStreamPlayer,
	# and a paused game (Engine.time_scale == 0) would otherwise produce one.
	var new_pitch: float = maxf(lerpf(1.0, max_pitch, eased) * Engine.time_scale, 0.01)
	if not is_equal_approx(new_pitch, pitch_scale):
		pitch_scale = new_pitch


func _resolve_train() -> void:
	_train = get_tree().get_first_node_in_group("train") as Train
	if _train == null:
		return
	# Primary stop trigger: player boarded — they've "made it," ticker has
	# done its job. `departed` is the safety net: if the player never boards,
	# the ticker still cuts off at depart() rather than bleeding into the
	# fail cinematic.
	_train.player_boarded.connect(stop)
	_train.departed.connect(stop)
