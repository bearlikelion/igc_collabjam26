class_name PlayerBrain
extends Brain

# Player brain. Reads keyboard input (left/right) via process_input forwarded
# from Pawn, and translates it into Pawn intent calls (request_lane_change /
# set_shuffle_telegraph / lean). The Pawn owns the camera, headbob, lane-lean
# spring, bullet-time, and visual show/hide — Brain doesn't touch any of that.
#
# All tunables live on the assigned `PlayerBrainConfig` Resource. PlayerBrain
# itself has zero @exports beyond the config slot — body feel + sensing
# lookaheads come from BrainConfig (the base type) via config.<field>.

## Per-archetype tunables. Authored as a .tres under
## Scenes/Characters/Brains/Configs/DefaultPlayer.tres. Required; null-config
## falls back to PlayerBrainConfig.new() defaults with a push_error.
@export var config: PlayerBrainConfig

var _lane_intent: int = 0

# Pawn we're stalled behind because they're SHUFFLING with someone else (e.g.
# an NPC-NPC shuffle in progress). While set, get_move_speed returns 0 so
# the player visibly halts; auto-clears when the peer becomes RUNNING. Same
# pattern as AIBrain._waiting_for — keeps the UX consistent across roles.
var _waiting_for: Pawn


func _on_bound() -> void:
	if config == null:
		push_error("PlayerBrain on '%s' has no config — using PlayerBrainConfig.new() defaults." % pawn.name)
		config = PlayerBrainConfig.new()
	pawn.add_to_group("player")
	# Resolve the singleton PlayerCamera (lives at level scene root, in group
	# "player_camera"), wire it to this Pawn. NPCs never run this branch, so
	# the rig has exactly one target ever.
	var rig: PawnCamera = pawn.get_tree().get_first_node_in_group("player_camera") as PawnCamera
	if rig != null:
		pawn.camera_rig = rig
		rig.set_target(pawn)
	else:
		push_warning("PlayerBrain: no PawnCamera in group \"player_camera\" — camera intents will no-op.")
	# The player Pawn owns the active camera and bullet-time. NPC brains
	# leave both off — Pawn stays role-agnostic until a brain claims it.
	pawn.set_camera_active(true)
	pawn.set_bullet_time_owner(true)


# Player wants MetroMovement to scan for environment obstacles every frame.
# When something is in the lane, _on_obstacle_detected handles the response.
func should_avoid_obstacles() -> bool:
	return true


func get_obstacle_lookahead() -> float:
	return config.obstacle_lookahead


func get_encounter_lookahead() -> float:
	return config.encounter_lookahead


# Body feel-tunables — read from the shared BrainConfig fields.

func get_start_speed() -> float:
	return config.start_speed


func get_max_speed() -> float:
	return config.max_speed


func get_acceleration_time() -> float:
	return config.acceleration_time


func get_shuffle_recovery_time() -> float:
	return config.shuffle_recovery_time


func get_shuffle_get_up_time() -> float:
	return config.shuffle_get_up_time


func get_shuffle_knockback_distance() -> float:
	return config.shuffle_knockback_distance


func _on_obstacle_detected(_blocker: Node, _distance: float, _in_lane: int, _candidate_lanes: Array[int]) -> void:
	pawn.knock_down_from_shuffle()


func get_end_of_rail_action() -> int:
	return EndOfRailAction.GOAL


# Player's current speed lives on Pawn (start_speed → max_speed acceleration
# curve, mutated by knockdown / movement_blocked / goal_reached). MetroMovement
# queries every runner through this method, so PlayerBrain forwards Pawn's
# physical speed instead of owning a separate value — except while waiting
# behind a busy peer (zero), or modulated to match a same-direction peer
# ahead in the same lane (cap at peer speed, no catch-up).
func get_move_speed() -> float:
	if _waiting_for != null:
		if not is_instance_valid(_waiting_for) or not _waiting_for.is_runner_paused():
			_waiting_for = null
		else:
			return 0.0
	return modulate_for_same_direction_peer(pawn.run_speed)


# Called by Pawn._input for every input event. During an active shuffle, the
# telegraph mirrors the currently-held direction (tap to choose, release
# returns to stay, both-held cancels) — same surface as normal lane input
# pressed/released states, but the shuffle resolves at deadline rather than
# on release. Outside shuffle, route to lane intent (press) and lane commit
# (release).
func process_input(event: InputEvent) -> void:
	if pawn == null:
		return
	if pawn.is_shuffle_active():
		if event.is_action_pressed("left") or event.is_action_pressed("right") \
				or event.is_action_released("left") or event.is_action_released("right"):
			var held: int = _get_held_direction()
			pawn.set_shuffle_telegraph(held)
			pawn.lean(held)
		return
	if pawn.is_knocked_down() or not pawn.can_move():
		return
	if event.is_action_pressed("left"):
		_on_lane_input_press(-1)
	elif event.is_action_pressed("right"):
		_on_lane_input_press(1)
	elif event.is_action_released("left") or event.is_action_released("right"):
		_on_lane_input_release()


func _on_lane_change_canceled() -> void:
	# A shuffle interrupted our tween — reset camera-lean intent.
	_lane_intent = 0
	pawn.lean(0)


func _on_recovered() -> void:
	# Require a fresh press to lane-change after recovery.
	_lane_intent = 0
	pawn.lean(0)


func _on_encounter_detected(other: Pawn, _distance: float) -> void:
	if other == null:
		return
	# Same-direction peer (NPC walking the same way as the player): no
	# shuffle, no knockdown — get_move_speed caps us at their speed so we
	# trail them. Knockback should only fire on head-on collisions.
	if other.is_routing_to_finish_point() == pawn.is_routing_to_finish_point():
		_waiting_for = null
		return
	# Busy NPC (already in another shuffle): stop and wait until they free up.
	# Pawn.start_shuffle would no-op via its hard guard, but we want the
	# visible halt and the run_speed reset so the player doesn't accelerate
	# during the wait.
	if other.is_runner_paused():
		_waiting_for = other
		pawn.run_speed = config.start_speed
		return
	_waiting_for = null
	pawn.start_shuffle(other)


# Press handler — set lane intent. Cancels intent if both keys are now held.
func _on_lane_input_press(direction: int) -> void:
	if not pawn.can_move() or pawn.is_knocked_down() or pawn.is_movement_blocked() or pawn.is_goal_reached():
		return
	var both_held: bool = Input.is_action_pressed("left") and Input.is_action_pressed("right")
	_lane_intent = 0 if both_held else direction
	pawn.lean(_lane_intent)


# Release handler — commit the lane change if no other key is still held.
func _on_lane_input_release() -> void:
	var still_held: bool = Input.is_action_pressed("left") or Input.is_action_pressed("right")
	if still_held:
		_lane_intent = -1 if Input.is_action_pressed("left") else 1
		pawn.lean(_lane_intent)
		return
	if pawn.can_move() and not pawn.is_knocked_down() and not pawn.is_movement_blocked() and not pawn.is_goal_reached():
		var next_lane: int = clampi(pawn.get_current_lane() + _lane_intent, 0, Pawn.LANE_COUNT - 1)
		if next_lane != pawn.get_current_lane():
			pawn.request_lane_change(next_lane)
	_lane_intent = 0
	pawn.lean(0)


func _get_held_direction() -> int:
	var direction: int = 0
	if Input.is_action_pressed("left"):
		direction -= 1
	if Input.is_action_pressed("right"):
		direction += 1
	return clampi(direction, -1, 1)
