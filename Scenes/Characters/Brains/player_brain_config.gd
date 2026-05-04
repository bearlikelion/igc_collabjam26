class_name PlayerBrainConfig
extends BrainConfig

# Player-specific tunables. Empty body today — every player tunable that
# existed (obstacle_lookahead, encounter_lookahead) lives on the BrainConfig
# base because both PlayerBrain and AIBrain consume the same surface.
# Kept as a typed marker so:
#   1. PlayerBrain's @export var config: PlayerBrainConfig is type-safe
#      (the inspector won't let an AIBrainConfig.tres slip in).
#   2. Future player-only tunables (UI hints, input dead zones, etc.)
#      have a clear home.
