extends SceneTree

## Headless training/smoke runner. Usage:
##   godot --headless --path simulator -s res://src/cli/headless_runner.gd -- \
##       --training --scenario=waypoint --seed=1234 --agents=4 --steps=1000 \
##       [--controller=waypoint|random|zero]
##
## Loads the simulation, resets the scenario, runs a scripted policy and
## prints a machine-readable summary (KEY VALUE lines), including a SHA-256
## hash of the final logical state for determinism checks. Exits non-zero on
## any failure; never requires GUI interaction.

const SUMMARY_KEYS := [
	"SCENARIO", "SEED", "AGENTS", "STEPS_RUN", "TERMINATED", "TRUNCATED",
	"TOTAL_REWARD", "SUCCESSES", "COLLISIONS", "MEAN_DIST", "WALL_MS",
	"STATE_HASH",
]


func _initialize() -> void:
	var opts := _parse_args(OS.get_cmdline_user_args())

	var scenario_name: String = opts.get("scenario", "waypoint")
	var seed: int = int(opts.get("seed", "1234"))
	var agents: int = int(opts.get("agents", "4"))
	var max_steps: int = int(opts.get("steps", "1000"))
	var controller_name: String = opts.get("controller", "waypoint")

	var config := SimConfig.new()
	var env := SwarmEnv.new()
	if not env.configure(config):
		_fail("configure failed: " + env.last_error)
		return
	if not env.reset(seed, scenario_name, agents):
		_fail("reset failed: " + env.last_error)
		return

	var controller := _make_controller(controller_name, env.get_spec())
	if controller == null:
		_fail("unknown controller '%s'" % controller_name)
		return

	var t0 := Time.get_ticks_msec()
	var total_reward := 0.0
	var steps_run := 0
	var obs: Array = env.get_observations()

	for _i in range(max_steps):
		var actions: Array = controller.compute_actions(obs, env.rng)
		if not env.apply_actions(actions):
			_fail("apply_actions failed: " + env.last_error)
			return
		if not env.step():
			_fail("step failed: " + env.last_error)
			return
		steps_run += 1
		for r in env.get_rewards():
			total_reward += r
		obs = env.get_observations()
		if env.is_terminated() or env.is_truncated():
			break

	var info: Dictionary = env.get_info()
	var summary := {
		"SCENARIO": scenario_name,
		"SEED": seed,
		"AGENTS": agents,
		"STEPS_RUN": steps_run,
		"TERMINATED": int(env.is_terminated()),
		"TRUNCATED": int(env.is_truncated()),
		"TOTAL_REWARD": "%.6f" % total_reward,
		"SUCCESSES": info["successes"],
		"COLLISIONS": info["collisions"],
		"MEAN_DIST": "%.6f" % info["mean_distance_to_target"],
		"WALL_MS": Time.get_ticks_msec() - t0,
		"STATE_HASH": _hash_state(env),
	}
	for key in SUMMARY_KEYS:
		print("%s %s" % [key, summary[key]])
	quit(0)


func _fail(msg: String) -> void:
	printerr("headless_runner: " + msg)
	quit(1)


func _parse_args(args: PackedStringArray) -> Dictionary:
	var opts := {}
	for arg in args:
		if arg.begins_with("--"):
			var kv := arg.trim_prefix("--").split("=", true, 1)
			if kv.size() == 2:
				opts[kv[0]] = kv[1]
			else:
				opts[kv[0]] = true
	return opts


func _make_controller(p_name: String, spec: Dictionary) -> ScriptedController:
	var c: ScriptedController
	match p_name:
		"zero":
			c = ZeroController.new()
		"random":
			c = RandomController.new()
		"waypoint":
			c = WaypointController.new()
		_:
			return null
	c.configure(spec)
	return c


func _hash_state(env: SwarmEnv) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(env.sim.snapshot_packed().to_byte_array())
	return ctx.finish().hex_encode()
