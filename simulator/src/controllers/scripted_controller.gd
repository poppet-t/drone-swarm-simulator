class_name ScriptedController
extends RefCounted

## Base class for scripted policies. Controllers consume observations and
## emit actions through the exact same interface Julia will use — they never
## touch drone state directly.
##
## The RNG is owned by the caller (seeded from the environment reset seed),
## so controller randomness follows the same deterministic seed flow.

var spec: Dictionary = {}


func configure(p_spec: Dictionary) -> void:
	spec = p_spec


## Returns one PackedFloat32Array of size action_size per agent.
func compute_actions(observations: Array, _rng: RandomNumberGenerator) -> Array:
	var actions: Array = []
	var action_size: int = spec.get("action_size", DroneDynamics.ACTION_SIZE)
	for _i in range(observations.size()):
		actions.append(PackedFloat32Array(
			[0.0, 0.0, 0.0, 0.0].slice(0, action_size)))
	return actions
