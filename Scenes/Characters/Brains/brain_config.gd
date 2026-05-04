class_name BrainConfig
extends Resource

# Shared "feel" tunables for any Brain. Authored as .tres files so swapping a
# Pawn's brain.config = different archetype with zero code change.
#
# Subclasses (AIBrainConfig, PlayerBrainConfig) add role-specific fields.
# Pawn never reads these directly — Pawn calls brain.get_X() virtuals which
# resolve to config.<field>. Keeps the Pawn↔Brain contract narrow.

@export_group("Run Speed")
@export var start_speed: float = 0.5
@export var max_speed: float = 3.0
## Time in seconds to accelerate from start_speed to max_speed.
@export var acceleration_time: float = 10.0

@export_group("Knockdown")
## Total knockdown lockout in seconds.
@export var shuffle_recovery_time: float = 2.5
## Get-up window inside the lockout — recover anim starts when remaining ≤ this.
@export var shuffle_get_up_time: float = 1.0
## Distance to push the pawn away from the impact origin on knockdown.
@export var shuffle_knockback_distance: float = 2.0

@export_group("Sensing")
## Forward distance the obstacle scan looks ahead. Brain's response varies:
## PlayerBrain knocks down on contact; AIBrain swerves to a clear lane.
@export var obstacle_lookahead: float = 2.0
## Rail-distance the encounter scan looks ahead for other Pawns in the same
## lane. Replaces the legacy 2 m forward ShuffleCast.
@export var encounter_lookahead: float = 2.0
