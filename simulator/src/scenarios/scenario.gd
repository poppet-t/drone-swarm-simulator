class_name Scenario
extends RefCounted

## Scenario-independent interface between SwarmEnv and concrete episodes.
## A scenario owns spawn logic, observations, rewards and termination, and
## must be fully driven by the seeded RNG handed to setup().

var scenario_name := "base"


## Scenario factory. Add new scenarios here.
static func create(p_name: String) -> Scenario:
	match p_name:
		"waypoint":
			return WaypointScenario.new()
	push_error("Scenario.create: unknown scenario '%s'" % p_name)
	return null


static func available() -> Array[String]:
	return ["waypoint"]


## Builds spawn states and the static world from the seeded RNG.
## Returns {"states": Array[DroneState], "obstacles": Array[AABB]}.
func setup(_rng: RandomNumberGenerator, _agent_count: int,
		_config: SimConfig) -> Dictionary:
	push_error("Scenario.setup: not implemented")
	return {}


## Per-agent observation vectors, fixed size for the whole episode.
func build_observations(_sim: SwarmSimulation) -> Array:
	return []


## Per-agent reward for the last committed step.
func compute_rewards(_sim: SwarmSimulation) -> PackedFloat32Array:
	return PackedFloat32Array()


func is_terminated(_sim: SwarmSimulation) -> bool:
	return false


func is_truncated(_sim: SwarmSimulation) -> bool:
	return false


## Observation/action space description for external clients (Julia).
func get_spec(_config: SimConfig, _agent_count: int) -> Dictionary:
	return {}


func get_info(_sim: SwarmSimulation) -> Dictionary:
	return {}


## Episode length used by observation version 2's time_fraction field.
func max_episode_steps() -> int:
	return 500


## Mission block of observation version 2 for agent `index` (raw values; the
## builder normalizes). Returns:
##   goal: Vector3 world-space subgoal/target,
##   progress: float [0, 1],
##   phase_code: float in [0, max_phase_count),
##   max_phase_count: float > 0,
##   success: bool.
## The base implementation reports a zeroed mission (no goal).
func build_mission_v2(_sim: SwarmSimulation, _index: int) -> Dictionary:
	return {"goal": Vector3.ZERO, "progress": 0.0, "phase_code": 0.0,
		"max_phase_count": 1.0, "success": false}
