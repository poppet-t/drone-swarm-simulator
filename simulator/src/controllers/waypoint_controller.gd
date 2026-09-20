class_name WaypointController
extends ScriptedController

## Hand-written proportional controller for the waypoint scenario.
## Accelerates toward the target and brakes with the velocity term; yaw rate
## is left at zero. Acts on observations only.

var position_gain := 6.0
var velocity_gain := 1.0


func compute_actions(observations: Array, _rng: RandomNumberGenerator) -> Array:
	var layout: Dictionary = spec.get("obs_layout", {})
	var i_pos: int = layout.get("position", 0)
	var i_vel: int = layout.get("velocity", 3)
	var i_rel: int = layout.get("rel_target", 8)
	var i_active: int = layout.get("active", 18)

	# rel_target is normalized by the world diagonal; undo that scaling so
	# the gain acts on a roughly meter-scale error.
	var diag := 60.0  # conservative over-estimate; clamping bounds the result
	var actions: Array = []
	for obs in observations:
		if obs[i_active] < 0.5:
			actions.append(PackedFloat32Array([0.0, 0.0, 0.0, 0.0]))
			continue
		var a := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
		for axis in range(3):
			var err: float = obs[i_rel + axis] * diag
			var vel: float = obs[i_vel + axis] * 6.0  # approx max_speed denorm
			a[axis] = clampf(position_gain * err - velocity_gain * vel,
				-1.0, 1.0)
		actions.append(a)
	return actions
