class_name AIBrain
extends Brain

# AI brain. Drives an NPC's lane decisions and shuffle telegraph. Reacts to
# Pawn signals and ticks msec-timestamped timers via physics_tick (no Timer
# nodes — Brain is a Resource and can't have child nodes).

@export var random_lane_changes: bool = false
@export_range(0.5, 30.0, 0.5) var random_lane_interval_min: float = 3.0
@export_range(0.5, 30.0, 0.5) var random_lane_interval_max: float = 7.0

var _next_random_lane_msec: int = 0
var _avoidance_until_msec: int = 0


# --- Brain hooks ----------------------------------------------------------

func _on_bound() -> void:
	pawn.add_to_group("npc")
	if random_lane_changes:
		_next_random_lane_msec = Time.get_ticks_msec() + int(_next_random_lane_delay() * 1000.0)


func physics_tick(_delta: float) -> void:
	if not random_lane_changes:
		return
	if Time.get_ticks_msec() < _next_random_lane_msec:
		return
	var clear_lane: int = _pick_random_other_lane(pawn.get_current_lane())
	if clear_lane != pawn.get_current_lane():
		pawn.set_current_lane(clear_lane)
	_next_random_lane_msec = Time.get_ticks_msec() + int(_next_random_lane_delay() * 1000.0)


func _on_encounter_detected(other: Pawn, _distance: float) -> void:
	if other == null:
		return
	# NPCs don't initiate shuffles. Swerve only if the other can't react
	# (knocked-down player) or another NPC blocking the lane. An active player
	# keeps holding the lane so the player's dodge mechanic still triggers.
	if not other.is_in_group("npc") and not other.is_runner_paused():
		return
	if Time.get_ticks_msec() < _avoidance_until_msec:
		return
	var clear_lane: int = _pick_random_other_lane(pawn.get_current_lane())
	if clear_lane != pawn.get_current_lane():
		pawn.set_current_lane(clear_lane)
		_avoidance_until_msec = Time.get_ticks_msec() + int(pawn.avoidance_cooldown * 1000.0)


func _on_shuffle_began(_other: Pawn, _other_telegraph: int, _deadline_msec: int) -> void:
	# Stage 3 baseline: roll a random direction. Stage 4 archetypes will
	# override this for variety (lean-toward-player, late-lean, feint, etc.)
	var direction: int = -1 if randf() < 0.5 else 1
	pawn.lean(direction)
	pawn.set_shuffle_telegraph(direction)


# --- Helpers --------------------------------------------------------------

func _pick_random_other_lane(current: int) -> int:
	if Pawn.LANE_COUNT <= 1:
		return current
	var choices: Array[int] = []
	for lane: int in range(Pawn.LANE_COUNT):
		if lane != current:
			choices.append(lane)
	if choices.is_empty():
		return current
	return choices[randi() % choices.size()]


func _next_random_lane_delay() -> float:
	var lo: float = minf(random_lane_interval_min, random_lane_interval_max)
	var hi: float = maxf(random_lane_interval_min, random_lane_interval_max)
	if hi <= 0.0:
		return 1.0
	return lo + randf() * maxf(hi - lo, 0.0)
