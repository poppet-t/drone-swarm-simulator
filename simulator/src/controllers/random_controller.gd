class_name RandomController
extends ScriptedController

## Uniform random actions in [-1, 1]^4 drawn from the caller's seeded RNG.

func compute_actions(observations: Array, rng: RandomNumberGenerator) -> Array:
	var actions: Array = []
	for _i in range(observations.size()):
		actions.append(PackedFloat32Array([
			rng.randf_range(-1.0, 1.0),
			rng.randf_range(-1.0, 1.0),
			rng.randf_range(-1.0, 1.0),
			rng.randf_range(-1.0, 1.0)]))
	return actions
