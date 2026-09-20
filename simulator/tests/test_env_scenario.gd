extends TestCase

## Environment API, observations, rewards, termination and headless smoke.


func test_spec_shape() -> void:
	var env := make_env(1, 4)
	var spec := env.get_spec()
	check_eq(spec["obs_size"], WaypointScenario.OBS_SIZE, "obs size in spec")
	check_eq(spec["action_size"], 4, "action size in spec")
	check_eq(spec["agent_count"], 4, "agent count in spec")
	check(spec.has("obs_layout"), "spec exposes the observation layout")


func test_observation_shape_and_mask() -> void:
	var env := make_env(1, 4)
	var obs: Array = env.get_observations()
	check_eq(obs.size(), 4, "one observation per agent")
	var ok := true
	for o in obs:
		if o.size() != WaypointScenario.OBS_SIZE:
			ok = false
		for v in o:
			if not is_finite(v):
				ok = false
	check(ok, "observations have fixed size and only finite values")
	for o in obs:
		check_eq(o[18], 1.0, "active mask set for fresh drones")


func test_waypoint_controller_reaches_target() -> void:
	# The proportional controller must solve the scenario headlessly:
	# all drones land, episode terminates before truncation.
	var env := make_env(1234, 4)
	var controller := WaypointController.new()
	controller.configure(env.get_spec())
	var steps := 0
	for _i in range(500):
		var actions: Array = controller.compute_actions(
			env.get_observations(), env.rng)
		env.apply_actions(actions)
		env.step()
		steps += 1
		if env.is_terminated() or env.is_truncated():
			break
	check(env.is_terminated(), "episode terminates (all drones landed)")
	check(not env.is_truncated(), "episode does not truncate")
	check_eq(env.get_info()["successes"], 4, "all drones succeeded")


func test_truncation_with_zero_action() -> void:
	# Hovering in place can never reach the target: must truncate at
	# max_steps, not terminate.
	var env := make_env(5, 1)
	for _i in range(600):
		env.apply_actions(zero_actions(1))
		env.step()
		if env.is_terminated() or env.is_truncated():
			break
	check(env.is_truncated(), "zero action truncates at max_steps")
	check(not env.is_terminated(), "zero action does not terminate")


func test_rewards_and_info() -> void:
	var env := make_env(1, 2)
	env.apply_actions(zero_actions(2))
	env.step()
	check_eq(env.get_rewards().size(), 2, "one reward per agent")
	var info := env.get_info()
	for key in ["steps", "successes", "active", "collisions",
		"mean_distance_to_target", "seed"]:
		check(info.has(key), "info has key " + key)


func test_headless_smoke() -> void:
	# Mirrors what the CLI runner does: seeded random policy, fixed steps.
	var env := make_env(2024, 4)
	var controller := RandomController.new()
	controller.configure(env.get_spec())
	var ok := true
	for _i in range(100):
		var actions: Array = controller.compute_actions(
			env.get_observations(), env.rng)
		if not env.apply_actions(actions) or not env.step():
			ok = false
			break
	check(ok, "100 headless random-policy steps without errors")
