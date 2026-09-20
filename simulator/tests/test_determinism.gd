extends TestCase

## Deterministic seeding and trajectory replay (Task 10).
##
## The whole episode derives from one reset seed: spawns, target, obstacle
## jitter and controller randomness. A fixed seed plus a fixed action
## sequence must reproduce the exact trajectory; on the pinned platform
## (Godot 4.7.1, Linux x86-64) we require bit-identical packed state,
## tolerance 0.

const REPLAY_STEPS := 200


func _fixed_action_sequence(seed: int, agents: int, steps: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var seq: Array = []
	for _i in range(steps):
		var step_actions: Array = []
		for _a in range(agents):
			step_actions.append(PackedFloat32Array([
				rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0),
				rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)]))
		seq.append(step_actions)
	return seq


func _run_fixed_sequence(env_seed: int, agents: int, seq: Array) -> PackedFloat32Array:
	var env := SwarmEnv.new()
	env.configure(SimConfig.new())
	env.reset(env_seed, "waypoint", agents)
	for step_actions in seq:
		if not env.apply_actions(step_actions):
			push_error("replay apply_actions failed: " + env.last_error)
			return PackedFloat32Array()
		env.step()
	return env.sim.snapshot_packed()


func test_deterministic_replay() -> void:
	var seq := _fixed_action_sequence(999, 4, REPLAY_STEPS)
	var first := _run_fixed_sequence(1234, 4, seq)
	var second := _run_fixed_sequence(1234, 4, seq)
	check(not first.is_empty(), "first replay produced state")
	check_eq(first, second,
		"fixed seed + fixed actions must replay bit-identically")


func test_controller_randomness_follows_reset_seed() -> void:
	# Two runs whose ONLY randomness is env.rng must match exactly.
	var run := func() -> PackedFloat32Array:
		var env := SwarmEnv.new()
		env.configure(SimConfig.new())
		env.reset(77, "waypoint", 3)
		var controller := RandomController.new()
		controller.configure(env.get_spec())
		for _i in range(100):
			var actions: Array = controller.compute_actions(
				env.get_observations(), env.rng)
			env.apply_actions(actions)
			env.step()
		return env.sim.snapshot_packed()
	check_eq(run.call(), run.call(),
		"seeded controller runs must match exactly")


func test_different_seeds_diverge() -> void:
	var seq := _fixed_action_sequence(999, 4, 50)
	var first := _run_fixed_sequence(1, 4, seq)
	var second := _run_fixed_sequence(2, 4, seq)
	check(first != second, "different seeds must diverge")
