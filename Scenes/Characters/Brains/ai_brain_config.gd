class_name AIBrainConfig
extends BrainConfig

# AI-specific tunables. Inherits BrainConfig's run-speed / knockdown / sensing
# groups. Authored as .tres files; swap a Pawn's brain.config = different
# AI archetype (e.g. Aggressive.tres, Stubborn.tres).

@export_group("Rail")
## Group name of the node this NPC walks toward. "finish" for same-direction
## runners, "player" for oncoming traffic. Resolved to a Node3D at bind time.
@export var destination_group: StringName = &"finish"
@export var spawn_distance: float = 0.0
@export var move_speed: float = 1.8
@export_range(0.0, 1.0, 0.01) var move_speed_variance: float = 0.3

@export_group("Lane Behavior")
@export var avoid_obstacles: bool = true
@export var avoidance_cooldown: float = 2.0
## Comfort gap (rail-meters) behind a same-direction peer. Inside this
## distance the AI slows below peer speed so the gap regrows — prevents
## convoy stacking. See `Brain.modulate_for_same_direction_peer`.
@export var min_peer_gap: float = 1.0
## When a same-direction peer ahead is throttling our speed (within
## `encounter_lookahead`), evaluate adjacent lanes and switch to the one with
## meaningfully more clearance. Reuses the obstacle-dodge cooldown so we
## don't lane-bounce. Disable for archetypes that should patiently trail
## (e.g. Stubborn parade-followers). See `_tick_overtake`.
@export var overtake_when_throttled: bool = true
## Extra clearance (rail-meters) the alternative lane must offer over the
## current lane before we commit to overtaking. Higher = more conservative
## swerves; prevents flipping between lanes that are equally congested.
## Defaults to one comfort gap so we only swap when the new lane is at
## least one peer-spacing roomier.
@export_range(0.0, 5.0, 0.1) var overtake_clearance_margin: float = 1.0
## Rail-meters of suppression window on either side of an interior corner.
## Inside this window `_tick_overtake` and `_tick_random_lane` skip — neither
## initiates a lane change. Counters the ~sqrt(2)*lane_offset world-space
## snap that hits non-center lanes at every 90° turn (see
## `MetroMovement._get_lane_segment_start` and the file header). Obstacle
## dodge and shuffle stance are NOT gated on this; they remain reactive at
## corners. 0.0 disables the gate entirely (legacy behaviour).
@export_range(0.0, 5.0, 0.1, "suffix:m") var corner_suppression_margin: float = 0.5

@export_group("Encounters")
## Rail-meters of clearance penalty applied per peer who is leaning INTO a
## candidate lane. Higher = more cautious (AI avoids lanes that peers are
## committing toward, even if currently empty). 0 = ignore peer leans.
@export_range(0.0, 5.0, 0.1) var lean_threat_weight: float = 1.0
## Wall-clock period (ms) between stance reroll considerations. Each tick
## passes through `stubbornness` first (random skip = keep current stance),
## then re-rolls via `_roll_stance` if not stubborn. Active during both
## run-up (after encounter detection) and the shuffle window. Lower =
## snappier reactions; 0 disables the reroll loop entirely (initial roll
## at encounter time persists).
@export_range(0, 500, 10, "suffix:ms") var reaction_period_ms: int = 50
# `inner_shuffle_radius` lives on `BrainConfig` — shared by PlayerBrain and AIBrain.
## 0–1: chance per re-roll tick the AI keeps its current stance instead of
## reconsidering. High values let peers read intent and exploit it (the
## telegraph stays committed); low values let the AI flicker between
## options. Applies during both run-up and the shuffle window.
@export_range(0.0, 1.0, 0.05) var stubbornness: float = 0.6
## 0–1: relative weight for picking "stay" (lean=0) when at least one
## adjacent lane is also clear. Bigger = more likely to claim the lane and
## stand upright instead of dodging. Forced to 1.0 (only choice) when both
## adjacents are blocked or out of bounds.
@export_range(0.0, 1.0, 0.05) var stay_chance: float = 0.3

@export_group("Random Lane")
@export var random_lane_changes: bool = false
@export_range(0.5, 30.0, 0.5) var random_lane_interval_min: float = 3.0
@export_range(0.5, 30.0, 0.5) var random_lane_interval_max: float = 7.0
