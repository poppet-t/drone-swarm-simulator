class_name TestObservationV2
extends TestCase

## Tests for the observation version 2 research contract (see
## docs/observation_v2.md): layout/offsets, structured<->flat conversion,
## determinism, finiteness, stable neighbour ordering, range sensor
## behaviour, communication model and inactive-agent representation.


func _make_v2_env(seed: int = 1234, agents: int = 4) -> SwarmEnv:
	var env := SwarmEnv.new()
	env.configure(SimConfig.new())
	if not env.reset(seed, "waypoint", agents, 2):
		push_error("v2 env reset failed: " + env.last_error)
		return null
	return env


func _step_n(env: SwarmEnv, n: int) -> void:
	for _i in range(n):
		env.apply_actions(zero_actions(env.sim.agent_count()))
		env.step()


func test_layout_constants_are_consistent() -> void:
	check_eq(ObservationV2.TOTAL_SIZE, 111, "total v2 size is 111")
	check_eq(ObservationV2.MISSION_OFFSET, ObservationV2.OWN_OFFSET \
		+ ObservationV2.OWN_SIZE, "mission block follows own state")
	check_eq(ObservationV2.RANGE_OFFSET, ObservationV2.MISSION_OFFSET \
		+ ObservationV2.MISSION_SIZE, "range block follows mission")
	check_eq(ObservationV2.NEIGHBOURS_OFFSET, ObservationV2.RANGE_OFFSET \
		+ ObservationV2.RAY_COUNT, "neighbour block follows range")
	check_eq(ObservationV2.COMM_OFFSET, ObservationV2.NEIGHBOURS_OFFSET \
		+ ObservationV2.NEIGHBOURS_SIZE, "comm block follows neighbours")
	check_eq(ObservationV2.COMM_OFFSET + ObservationV2.COMM_SIZE,
		ObservationV2.TOTAL_SIZE, "comm block ends at total size")


func test_flat_rows_have_documented_shape() -> void:
	var env := _make_v2_env(21, 4)
	var rows: Array = env.get_observations_v2()
	check_eq(rows.size(), 4, "one row per agent")
	for i in range(rows.size()):
		var row: PackedFloat32Array = rows[i]
		check_eq(row.size(), ObservationV2.TOTAL_SIZE, "row %d width" % i)
	# GET_SPEC layout matches the constants.
	var layout := ObservationV2.layout()
	check_eq(int(layout["size_per_agent"]), ObservationV2.TOTAL_SIZE,
		"layout advertises total size")
	check_eq(int(layout["blocks"]["neighbours"]["count"]),
		ObservationV2.K_NEIGHBOURS, "layout advertises K=6")


func test_structured_flatten_round_trip() -> void:
	var env := _make_v2_env(7, 5)
	_step_n(env, 3)
	var structured: Array = ObservationV2.build_structured(env.sim,
		env.scenario, env.config, env.comm_shadows)
	var flat: Array = env.get_observations_v2()
	check_eq(structured.size(), flat.size(), "same row count")
	for i in range(flat.size()):
		var packed := ObservationV2.flatten(structured[i])
		check_eq(packed.size(), ObservationV2.TOTAL_SIZE,
			"structured flatten width row %d" % i)
		var equal := true
		for k in range(packed.size()):
			if absf(packed[k] - flat[i][k]) > TOL:
				equal = false
				break
		check(equal, "structured->flat matches build_flat row %d" % i)


func test_own_state_fields_match_drone_state() -> void:
	var env := _make_v2_env(99, 1)
	var s: DroneState = env.sim.states[0]
	var row: PackedFloat32Array = env.get_observations_v2()[0]
	var config: SimConfig = env.config
	var centre := (config.bounds_min + config.bounds_max) * 0.5
	var half := (config.bounds_max - config.bounds_min) * 0.5
	check_approx(row[0], (s.position.x - centre.x) / half.x, TOL, "pos x norm")
	check_approx(row[3], s.velocity.x / config.max_speed, TOL, "vel x norm")
	check_approx(row[6], sin(s.yaw), TOL, "yaw sin")
	check_approx(row[7], cos(s.yaw), TOL, "yaw cos")
	check_approx(row[8], s.yaw_rate / config.max_yaw_rate, TOL, "yaw rate norm")
	check_approx(row[9], s.battery, TOL, "battery")
	check_eq(int(row[15]), 1, "active flag set for live drone")
	check_approx(row[16], 0.0, TOL, "time fraction zero at reset")


func test_time_fraction_advances() -> void:
	var env := _make_v2_env(3, 1)
	_step_n(env, 10)
	var row: PackedFloat32Array = env.get_observations_v2()[0]
	var expected := 10.0 / float(env.scenario.max_episode_steps())
	check_approx(row[16], expected, 1e-5, "time fraction after 10 steps")


func test_mission_block_reports_waypoint_goal() -> void:
	var env := _make_v2_env(55, 2)
	var scenario: WaypointScenario = env.scenario
	var rows: Array = env.get_observations_v2()
	var diag: float = env.config.bounds_min.distance_to(env.config.bounds_max)
	for i in range(2):
		var rel: Vector3 = scenario.target - env.sim.states[i].position
		check_approx(rows[i][17], rel.x / diag, TOL, "goal vec x row %d" % i)
		check_approx(rows[i][20], rel.length() / diag, TOL,
			"goal dist row %d" % i)
		check_eq(int(rows[i][23]), 0, "not successful yet row %d" % i)


func test_range_sensor_is_deterministic_and_logical() -> void:
	var env := _make_v2_env(1234, 1)
	var rows_a: Array = env.get_observations_v2()
	var rows_b: Array = env.get_observations_v2()
	for k in range(ObservationV2.RAY_COUNT):
		check_approx(rows_a[0][24 + k], rows_b[0][24 + k], 0.0,
			"ray %d repeatable" % k)

	# A drone next to the ground plane must see a short downward-ish hit but
	# free space upward; verify with direct casts instead of relying on spawn.
	var config := SimConfig.new()
	var origin := Vector3(0.0, config.bounds_min.y + config.drone_radius + 0.05,
		0.0)
	var down := ObservationV2.cast_ray(origin, Vector3.DOWN, config, [])
	var up := ObservationV2.cast_ray(origin, Vector3.UP, config, [])
	check(down < 0.01, "downward ray hits ground almost immediately (%f)" % down)
	check(up > 0.9, "upward ray reads near-free space (%f)" % up)

	# Obstacle AABB blocks the ray path at a known distance.
	var box := AABB(Vector3(5.0, -1.0, -0.5), Vector3(1.0, 6.0, 1.0))
	var boxes: Array[AABB] = [box]
	var hit := ObservationV2.cast_ray(origin + Vector3(0, 2, 0), Vector3.RIGHT,
		config, boxes)
	var expected := (5.0 - (origin.x)) / ObservationV2.RANGE_MAX_M
	check_approx(hit, expected, 1e-4, "ray stops at obstacle face")


func test_neighbour_ordering_distance_then_id() -> void:
	var env := SwarmEnv.new()
	env.configure(SimConfig.new())
	# Hand-built swarm: three drones at engineered distances from index 0;
	# ids equal their indices so ordering by distance is unambiguous except
	# for the equidistant pair (ids 2 and 3), which must order by id.
	var states: Array[DroneState] = []
	states.append(_state_at(0, Vector3.ZERO))
	states.append(_state_at(1, Vector3(3.0, 0, 0)))   # nearest
	states.append(_state_at(2, Vector3(-2.0, 0, 0)))  # second nearest
	states.append(_state_at(3, Vector3(2.0, 0, 0)))   # ties with id 2 on dist
	env.sim.reset(states)
	var structured: Array = ObservationV2.build_structured(env.sim,
		env.scenario if env.scenario != null else WaypointScenario.new(),
		env.config, env.comm_shadows)
	var nb: Array = structured[0]["neighbours"]
	check_eq(int(nb[0]["agent_id"]), 1, "nearest neighbour first")
	check_eq(int(nb[1]["agent_id"]), 2, "id 2 before id 3 at equal distance")
	check_eq(int(nb[2]["agent_id"]), 3, "id 3 third")
	check_eq(float(nb[0]["valid"]), 1.0, "slot 0 valid")
	check_eq(float(nb[3]["valid"]), 0.0, "empty slots masked out")


func test_communication_quality_decays_with_distance_and_shadow() -> void:
	var config := SimConfig.new() # radio_range 30, attenuation 0.1
	var q_near := ObservationV2.link_quality(Vector3.ZERO, Vector3(3, 0, 0),
		config, [])
	var q_far := ObservationV2.link_quality(Vector3.ZERO, Vector3(25, 0, 0),
		config, [])
	var q_out := ObservationV2.link_quality(Vector3.ZERO, Vector3(40, 0, 0),
		config, [])
	check(q_near > q_far, "closer drones have better link quality")
	check_approx(q_out, 0.0, TOL, "beyond radio range quality is zero")
	var shadows: Array[AABB] = [AABB(Vector3(1, -5, -5), Vector3(8, 10, 10))]
	var q_shadow := ObservationV2.link_quality(Vector3.ZERO, Vector3(3, 0, 0),
		config, shadows)
	check_approx(q_shadow, q_near * config.shadow_attenuation, 1e-6,
		"shadow attenuates the segment")
	check_approx(q_near, 1.0 - 3.0 / config.radio_range, 1e-6,
		"quality decays linearly with distance")


func test_inactive_agent_row_is_zero_masked() -> void:
	var env := SwarmEnv.new()
	env.configure(SimConfig.new())
	var states: Array[DroneState] = []
	states.append(_state_at(0, Vector3.ZERO))
	var dead := _state_at(1, Vector3(2, 0, 0))
	dead.active = false
	states.append(dead)
	env.sim.reset(states)
	var rows: Array = env.get_observations_v2()
	var all_zero := true
	for k in range(rows[1].size()):
		if absf(rows[1][k]) > 0.0:
			all_zero = false
			break
	check(all_zero, "inactive agent row is all zeros")
	check_eq(int(rows[1][15]), 0, "inactive own flag zero")
	# Active drone sees only the active peer; no slot may reference the dead
	# one — with one candidate there is exactly one valid slot.
	var structured: Array = ObservationV2.build_structured(env.sim,
		WaypointScenario.new(), env.config, env.comm_shadows)
	var nb: Array = structured[0]["neighbours"]
	check_eq(float(nb[0]["valid"]), 1.0, "active peer occupies slot 0")
	check_eq(float(nb[1]["valid"]), 0.0, "no ghost slots for inactive peers")


func test_deterministic_across_reseeds() -> void:
	var env_a := _make_v2_env(777, 4)
	var env_b := SwarmEnv.new()
	env_b.configure(SimConfig.new())
	env_b.reset(777, "waypoint", 4, 2)
	_step_n(env_a, 12)
	_step_n(env_b, 12)
	var rows_a: Array = env_a.get_observations_v2()
	var rows_b: Array = env_b.get_observations_v2()
	for i in range(rows_a.size()):
func test_version_one_path_untouched() -> void:
	var env := make_env(1234, 4) # default reset selects observation version 1
	check_eq(env.observation_version, 1, "default episode stays on v1")
	var rows: Array = env.get_observations()
	check_eq(rows.size(), 4, "v1 row count")
	check_eq(rows[0].size(), 23, "v1 width unchanged")
	check_eq(env.get_observations_v2().size(), 4,
		"both contracts available on one env")


func _state_at(id: int, pos: Vector3) -> DroneState:
	var s := DroneState.new()
	s.agent_id = id
	s.position = pos
	return s
				same = false
				break
		check(same, "identical seeds produce identical v2 rows (agent %d)" % i)


func test_all_values_finite_over_random_trajectories() -> void:
	for seed_i in range(3):
		var env := _make_v2_env(1000 + seed_i, 4)
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_i
		for step_i in range(60):
			var acts: Array = []
			for _a in range(env.sim.agent_count()):
				acts.append(PackedFloat32Array([
					rng.randf_range(-1, 1), rng.randf_range(-1, 1),
					rng.randf_range(-1, 1), rng.randf_range(-1, 1)]))
			if not env.apply_actions(acts):
				break
			env.step()
			for row_v in env.get_observations_v2():
				var row: PackedFloat32Array = row_v
				for k in range(row.size()):
					if not is_finite(row[k]):
						check(false, "non-finite value at seed %d step %d idx %d"
							% [seed_i, step_i, k])
						return
	check(true, "all observations finite across random trajectories")


func test_version_one_path_unchanged() -> void:
	var env := make_env(1234, 4) # v1 default reset
	var rows: Array = env.get_observations_v1_style_placeholder()


func _state_at(id: int, pos: Vector3) -> DroneState:
	var s := DroneState.new()
	s.agent_id = id
	s.position = pos
	return s
