class_name ZeroController
extends ScriptedController

## Always emits the zero action (hover). Useful as a sanity baseline.

func compute_actions(observations: Array, _rng: RandomNumberGenerator) -> Array:
	var actions: Array = []
	for _i in range(observations.size()):
		actions.append(PackedFloat32Array([0.0, 0.0, 0.0, 0.0]))
	return actions
