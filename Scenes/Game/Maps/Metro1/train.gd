class_name Train
extends Node3D

# Subway car at the end of the metro rail. Owns the depart cinematic, the
# audio, the slot-occupancy pool, and the departure countdown.
#
# Lifecycle (DepartState):
#   WAITING   — countdown ticks down, claim_slot accepts new boarders
#   DEPARTING — depart Tween running, claims refused, EndCamera holds the shot
#   DEPARTED  — Tween finished; success path holds, fail path resets the
#               level (sound → Engine.time_scale=1.0 → reload_current_scene)
#
# Time-pressure cues (Stage 4) layer on top of the WAITING-state countdown.

signal pawn_boarded(pawn: Pawn)
## Emitted the instant the player Pawn claims a slot — fires earlier than
## `pawn_boarded`'s player invocation by virtue of being the dedicated channel
## for "player made it." Listeners (clock ticker, win-stinger, HUD, etc.) wire
## here so they don't have to filter `pawn_boarded` by group membership.
signal player_boarded
## Emitted when `depart()` runs — EndCamera listens to flip its current state.
signal departed
## Emitted when the train_departure animation reaches its end. Win path holds
## on the cinematic, fail path resets the level.
signal cinematic_finished

enum DepartState { WAITING, DEPARTING, DEPARTED }

## Wall-equivalent seconds (scaled by Engine.time_scale via _process) from
## level load until the train pulls away. The player has to be `is_boarded`
## before this expires.
@export_range(1.0, 300.0, 0.5, "suffix:s") var departure_time: float = 90.0

# Position curve translated from the original train_departure AnimationPlayer
# track. Each Vector2 is (duration_s, z_offset_from_origin_m). Train pulls
# away in -Z; the first row is a hold at origin (slow start beat).
const DEPART_KEYFRAMES: Array[Vector2] = [
	Vector2(1.9666667, 0.0),
	Vector2(2.0333333, -10.0),
	Vector2(2.0, -20.0),
	Vector2(2.0, -61.5),
	Vector2(2.0, -261.5),
]

@onready var end_song: AudioStreamPlayer3D = $EndSong
@onready var depart_sound: AudioStreamPlayer3D = $DepartSound
@onready var fail_sound: AudioStreamPlayer = $FailSound
@onready var markers_root: Node3D = $Markers

# Collected from $Markers children on _ready. Indexed by slot order.
var _slots: Array[Marker3D] = []
# marker -> the Pawn occupying it. A pawn can only occupy one slot.
var _occupied: Dictionary[Marker3D, Pawn] = {}
var _depart_state: DepartState = DepartState.WAITING
var _time_left: float = 0.0


func _ready() -> void:
	add_to_group("train")
	_collect_slots()
	_time_left = departure_time


func _process(delta: float) -> void:
	if _depart_state != DepartState.WAITING:
		return
	_time_left -= delta
	if _time_left <= 0.0:
		_time_left = 0.0
		depart()


## Seconds left on the departure countdown. Stays at 0.0 once the train has
## left. Stage 4 reads this for the clock-tick pitch ramp + tannoy trigger.
func get_time_left() -> float:
	return _time_left


# Trigger the departure cinematic. Closes the claim window, plays the depart
# audio, kicks off the position Tween, and emits `departed` for EndCamera.
# Idempotent — repeated calls (e.g., timer AND a manual trigger) are no-ops
# once DEPARTING.
func depart() -> void:
	if _depart_state != DepartState.WAITING:
		return
	_depart_state = DepartState.DEPARTING
	departed.emit()
	if depart_sound.stream != null:
		depart_sound.play()
	# EndSong (the win jingle) only fires if the player actually made it on
	# board. Fail path plays the cinematic in silence, then `_play_fail_and_reset`
	# handles the missed-train SFX + level reload.
	var player: Pawn = get_tree().get_first_node_in_group("player") as Pawn
	if player != null and is_boarded(player) and end_song.stream != null:
		end_song.play()
	_start_depart_tween()


func _start_depart_tween() -> void:
	var origin: Vector3 = position
	var tween: Tween = create_tween()
	for kf: Vector2 in DEPART_KEYFRAMES:
		tween.tween_property(self, "position", origin + Vector3(0.0, 0.0, kf.y), kf.x)
	tween.tween_callback(_on_depart_tween_finished)


# Slot count is the source of truth for "how many forward NPCs can possibly
# board." MetroMovement reads this on level start to cap forward-direction
# spawns so late arrivals never exist.
func get_slot_count() -> int:
	return _slots.size()


# First-come-first-served claim. Returns the first free Marker3D, or null if
# the train is full OR has already departed. Emits `pawn_boarded` on success
# so observers (HUD, audio stinger, etc.) can react without polling.
func claim_slot(pawn: Pawn) -> Marker3D:
	if pawn == null:
		return null
	if _depart_state != DepartState.WAITING:
		return null
	for marker: Marker3D in _slots:
		if not _occupied.has(marker):
			_occupied[marker] = pawn
			pawn_boarded.emit(pawn)
			if pawn.is_in_group("player"):
				player_boarded.emit()
			return marker
	return null


# Symmetric API for the future — no Stage 3 caller, but kept for hypothetical
# "pawn knocked off train" features.
func release_slot(pawn: Pawn) -> void:
	for marker: Marker3D in _occupied.keys():
		if _occupied[marker] == pawn:
			_occupied.erase(marker)
			return


func is_boarded(pawn: Pawn) -> bool:
	for occupant: Pawn in _occupied.values():
		if occupant == pawn:
			return true
	return false


func _collect_slots() -> void:
	_slots.clear()
	for child: Node in markers_root.get_children():
		if child is Marker3D:
			_slots.append(child as Marker3D)


# Branch on whether the player made it onto the train. Success path is
# silent — EndCamera holds on the departed-train shot. Fail path plays the
# FailSound and resets the level (matching the existing `reset` action wiring
# in metro_movement.gd).
func _on_depart_tween_finished() -> void:
	if _depart_state != DepartState.DEPARTING:
		return
	_depart_state = DepartState.DEPARTED
	cinematic_finished.emit()
	var player: Pawn = get_tree().get_first_node_in_group("player") as Pawn
	if player != null and is_boarded(player):
		return
	_play_fail_and_reset()


func _play_fail_and_reset() -> void:
	# Reset time_scale before playing the fail SFX so it sounds right even if
	# the player happened to be mid-shuffle (Engine.time_scale = 0.2) when
	# the timer expired. Audio playback doesn't respect time_scale, but the
	# `await` timeout below does — pre-reset keeps both branches sane.
	Engine.time_scale = 1.0
	if fail_sound.stream != null:
		fail_sound.play()
		await fail_sound.finished
	else:
		await get_tree().create_timer(0.5).timeout
	get_tree().reload_current_scene()
