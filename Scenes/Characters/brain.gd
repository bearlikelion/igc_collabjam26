class_name Brain
extends Resource

# Base class for Pawn brains. Brains are Resources, not Nodes — assigned
# directly via @export on Pawn (no PackedScene indirection, no scene tree
# pollution). Each Pawn instance carries its own Brain Resource.
#
# Lifecycle:
#   1. Pawn._ready calls brain.bind(self). Brain stores the pawn reference,
#      wires up to the pawn's signal protocol, and runs _on_bound().
#   2. Pawn forwards input to brain via process_input(event) on every _input.
#   3. Pawn forwards physics ticks to brain via physics_tick(delta) on every
#      _physics_process — for time-based decisions that don't fit signals
#      (e.g., AI random lane-change timers, cooldowns).
#
# Subclasses (PlayerBrain, AIBrain) override the handlers they care about and
# call the Pawn's intent methods (request_lane_change / start_shuffle /
# set_shuffle_telegraph / lean) to drive the body.

var pawn: Pawn


# Bind to a Pawn. Connects signal handlers and runs the subclass _on_bound hook.
func bind(p: Pawn) -> void:
	pawn = p
	if pawn == null:
		push_error("Brain.bind called with null Pawn.")
		return
	pawn.lane_change_started.connect(_on_lane_change_started)
	pawn.lane_change_completed.connect(_on_lane_change_completed)
	pawn.lane_change_canceled.connect(_on_lane_change_canceled)
	pawn.encounter_detected.connect(_on_encounter_detected)
	pawn.shuffle_began.connect(_on_shuffle_began)
	pawn.shuffle_telegraph_changed.connect(_on_shuffle_telegraph_changed)
	pawn.shuffle_resolved.connect(_on_shuffle_resolved)
	pawn.knocked_down.connect(_on_knocked_down)
	pawn.recovery_started.connect(_on_recovery_started)
	pawn.recovered.connect(_on_recovered)
	pawn.obstacle_detected.connect(_on_obstacle_detected)
	pawn.goal_reached.connect(_on_goal_reached)
	_on_bound()


# Default no-op handlers. Subclasses override what they care about.

func _on_bound() -> void:
	pass


# Called by Pawn._input for every input event. Default no-op; PlayerBrain
# overrides to read keyboard.
func process_input(_event: InputEvent) -> void:
	pass


# Called by Pawn._physics_process every frame. Default no-op; AIBrain overrides
# for timer-driven decisions.
func physics_tick(_delta: float) -> void:
	pass


func _on_lane_change_started(_from: int, _to: int) -> void:
	pass


func _on_lane_change_completed(_lane: int) -> void:
	pass


func _on_lane_change_canceled() -> void:
	pass


func _on_encounter_detected(_other: Pawn, _distance: float) -> void:
	pass


func _on_shuffle_began(_other: Pawn, _other_telegraph: int, _deadline_msec: int) -> void:
	pass


func _on_shuffle_telegraph_changed(_direction: int) -> void:
	pass


func _on_shuffle_resolved(_succeeded: bool, _direction: int) -> void:
	pass


func _on_knocked_down() -> void:
	pass


func _on_recovery_started() -> void:
	pass


func _on_recovered() -> void:
	pass


func _on_obstacle_detected(_other: Pawn, _distance: float, _in_lane: int) -> void:
	pass


func _on_goal_reached() -> void:
	pass
