extends TestCase

## Startup, reset, fixed-timestep, action clamping, NaN/Inf rejection and
## speed-limit tests.


func test_config_defaults_valid() -> void:
	check(SimConfig.new().validate(), "default SimConfig must be valid")


func test_env_boots_and_agent_order() -> void:
	var env := make_env(7, 5)
	check(env != null, "env boots")
	if env == null:
		return
	check_eq(env.sim.agent_count(), 5, "agent count")
	for i in range(5):
		check_eq(env.sim.states[i].agent_id, i, "agent id at index %d" % i)


func test_reset_deterministic_spawns() -> void:
	var env := make_env(42, 3)
	var first: PackedFloat32Array = env.sim.snapshot_packed()
	env.reset(42, "waypoint", 3)
	var second: PackedFloat32Array = env.sim.snapshot_packed()
	check_eq(first, second, "same seed must reproduce identical spawn state")


func test_reset_different_seeds_differ() -> void:
	var env := make_env(42, 3)
	var first: PackedFloat32Array = env.sim.snapshot_packed()
	env.reset(43, "waypoint", 3)
	var second: PackedFloat32Array = env.sim.snapshot_packed()
	check(first != second, "different seeds must produce different spawns")


func test_fixed_timestep_integration() -> void:
	# One step with a constant action must equal exactly physics_substeps
	# semi-implicit Euler substeps at physics_dt — the fixed-timestep proof.
	var env := make_env(1, 1)
	var config := env.config
	env.apply_actions([PackedFloat32Array([1.0, 0.0, 0.0, 0.0])])
	var v0: Vector3 = env.sim.states[0].velocity
	env.step()
	var v := v0
	for _i in range(config.physics_substeps):
		var accel := Vector3(config.max_accel, 0, 0) - config.linear_drag * v
		v += accel * config.physics_dt
		if v.length() > config.max_speed:
			v = v.normalized() * config.max_speed
	check_vec3_approx(env.sim.states[0].velocity, v, 1e-6,
		"velocity after one step matches analytic fixed-step integration")
	check_eq(env.sim.step_count, 1, "step count after one step")


func test_hover_compensation_holds_altitude() -> void:
	var env := make_env(1, 1)
	var y0: float = env.sim.states[0].position.y
	env.apply_actions(zero_actions(1))
	for _i in range(10):
		env.step()
	check_approx(env.sim.states[0].position.y, y0, 1e-6,
		"zero action must hold altitude (hover compensation)")


func test_action_clamping() -> void:
	var env := make_env(1, 1)
	check(env.apply_actions([PackedFloat32Array([10.0, -10.0, 2.0, -5.0])]),
		"out-of-range actions are accepted but clamped")
	env.step()
	var prev: Vector4 = env.sim.states[0].previous_action
	check_eq(prev, Vector4(1, -1, 1, -1), "clamped action stored in state")


func test_nan_and_inf_rejection() -> void:
	var env := make_env(1, 1)
	check(not env.apply_actions([PackedFloat32Array([NAN, 0.0, 0.0, 0.0])]),
		"NaN action rejected")
	check(not env.apply_actions([PackedFloat32Array([0.0, INF, 0.0, 0.0])]),
		"Inf action rejected")
	check(not env.apply_actions([PackedFloat32Array([0.0, 0.0, 0.0])]),
		"wrong-size action rejected")
	check(not env.apply_actions(zero_actions(2)),
		"wrong action count rejected")
	check(not env.last_error.is_empty(), "rejection records an error message")
	var pos_before: Vector3 = env.sim.states[0].position
	var vel_before: Vector3 = env.sim.states[0].velocity
	env.step()  # falls back to the default zero action (hover)
	check_vec3_approx(env.sim.states[0].position, pos_before, 1e-6,
		"rejected actions must not move the drone")
	check_vec3_approx(env.sim.states[0].velocity, vel_before, 1e-6,
		"rejected actions must not change velocity")


func test_max_speed_enforced() -> void:
	var env := make_env(1, 1)
	env.apply_actions([PackedFloat32Array([1.0, 1.0, 1.0, 0.0])])
	var limit: float = env.config.max_speed
	var ok := true
	for _i in range(100):
		env.step()
		if env.sim.states[0].velocity.length() > limit + 1e-4:
			ok = false
			break
	check(ok, "speed never exceeds max_speed under sustained max action")
