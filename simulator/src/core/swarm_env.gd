class_name SwarmEnv
extends RefCounted

## Scenario-independent environment API — the future Julia boundary.
##
## One instance = one episode context. Typical use:
##   env.configure(config)
##   env.reset(seed, "waypoint", agent_count)
##   var obs := env.get_observations()
##   while not (env.is_terminated() or env.is_truncated()):
##       if env.apply_actions(actions):
##           env.step()
##       obs = env.get_observations()
##
## Julia submits actions only; Godot advances the dynamics. Julia can never
## set drone positions directly through this API.

var config: SimConfig
var sim: SwarmSimulation
var scenario: Scenario
var seed: int = 0
## Communication shadow regions (map-authored AABBs) used by observation
## version 2's link-quality model. Empty unless the scenario provides them.
var comm_shadows: Array[AABB] = []
## Observation contract selected for this episode (1 or 2); set at reset.
var observation_version: int = 1

## Single source of randomness for the whole episode: scenario setup and any
## stochastic controllers derive from this seed (see HeadlessRunner).
var rng: RandomNumberGenerator

var last_error: String = ""

var _pending_actions: Array = []
var _has_actions := false
var _rewards := PackedFloat32Array()


func configure(p_config: SimConfig) -> bool:
	if not p_config.validate():
		last_error = "invalid SimConfig"
		return false
	config = p_config
	return true


func reset(p_seed: int, scenario_name: String = "waypoint",
		agent_count: int = 1, p_observation_version: int = 1) -> bool:
	if config == null:
		config = SimConfig.new()
	if agent_count < 1:
		last_error = "agent_count must be >= 1"
		push_error("SwarmEnv.reset: " + last_error)
		return false

	seed = p_seed
	rng = RandomNumberGenerator.new()
	rng.seed = seed

	scenario = Scenario.create(scenario_name)
	if scenario == null:
		last_error = "unknown scenario '%s'" % scenario_name
		push_error("SwarmEnv.reset: " + last_error)
		return false

	sim = SwarmSimulation.new(config)
	var world: Dictionary = scenario.setup(rng, agent_count, config)
	sim.reset(world["states"], world["obstacles"])
	comm_shadows = []
	for shadow_v in world.get("comm_shadows", []):
		comm_shadows.append(shadow_v)
	observation_version = p_observation_version

	_pending_actions = []
	for i in range(sim.agent_count()):
		_pending_actions.append(Vector4.ZERO)
	_has_actions = false
	_rewards = PackedFloat32Array()
	_rewards.resize(sim.agent_count())
	last_error = ""
	return true


func get_spec() -> Dictionary:
	return scenario.get_spec(config, sim.agent_count())


func get_observations() -> Array:
	return scenario.build_observations(sim)


## Observation version 2 vectors (see ObservationV2). Independent of the
## version-1 path so legacy observations stay byte-identical.
func get_observations_v2() -> Array:
	return ObservationV2.build_flat(sim, scenario, config, comm_shadows)


## Validates and stores one action per agent. Invalid input (wrong count,
## wrong shape, NaN/Inf) is rejected: nothing is stored and step() will keep
## the previous actions. Actions are clamped to [-1, 1]^4 here, once.
func apply_actions(actions: Array) -> bool:
	if sim == null:
		last_error = "apply_actions before reset"
		push_error("SwarmEnv: " + last_error)
		return false
	if actions.size() != sim.agent_count():
		last_error = "expected %d actions, got %d" % [sim.agent_count(), actions.size()]
		push_error("SwarmEnv.apply_actions: " + last_error)
		return false
	var clamped: Array = []
	for i in range(actions.size()):
		var raw: PackedFloat32Array = actions[i]
		if not DroneDynamics.action_is_valid(raw):
			last_error = "invalid action for agent %d (size %d, finite %s)" % [
				i, raw.size(), DroneDynamics.action_is_valid(raw)]
			push_error("SwarmEnv.apply_actions: " + last_error)
			return false
		clamped.append(DroneDynamics.clamp_action(raw))
	_pending_actions = clamped
	_has_actions = true
	return true


## Advances the environment by one policy step. If no actions were applied
## since reset, zero actions are used (documented default).
func step() -> bool:
	if sim == null:
		last_error = "step before reset"
		push_error("SwarmEnv: " + last_error)
		return false
	var result: Dictionary = sim.step(_pending_actions)
	if result["fail"]:
		last_error = result["msg"]
		push_error("SwarmEnv.step: " + last_error)
		return false
	_rewards = scenario.compute_rewards(sim)
	return true


func is_terminated() -> bool:
	return scenario.is_terminated(sim)


func is_truncated() -> bool:
	return scenario.is_truncated(sim)


func get_rewards() -> PackedFloat32Array:
	return _rewards


func get_info() -> Dictionary:
	var info: Dictionary = scenario.get_info(sim)
	info["seed"] = seed
	info["last_error"] = last_error
	return info
