class_name PlayerBrainConfig
extends BrainConfig

## Near-miss qualifier rail-distance. 0.0 = follow `inner_shuffle_radius`
## (lockstep with mini-game trigger). Above `inner_shuffle_radius` widens
## the reward zone past the danger zone. Setter clamps non-zero values
## up to `inner_shuffle_radius`.
@export_range(0.0, 5.0, 0.05) var near_miss_radius: float = 0.0:
	set(value):
		if value <= 0.0:
			near_miss_radius = 0.0
		else:
			near_miss_radius = maxf(value, inner_shuffle_radius)


func get_resolved_near_miss_radius() -> float:
	if near_miss_radius <= 0.0:
		return inner_shuffle_radius
	return near_miss_radius
