extends TestCase

## FSYNC compute-all-then-commit semantics, stable agent ordering and
## collision reporting.


func _spawn(id: int, pos: Vector3, battery: float = 1.0) -> DroneState:
	var s := DroneState.new()
	s.agent_id = id
	s.position = pos
	s.battery = battery
	return s


func test_compute_all_before_commit() -> void:
	# Instrumented proof: while drone i's next state is being computed,
	# every earlier drone's next state already exists, yet the committed
	# swarm state is still the pre-step state for ALL drones.
	var sim := SwarmSimulation.new(SimConfig.new())
	sim.reset([_spawn(0, Vector3.ZERO), _spawn(1, Vector3(2, 0, 0)),
		_spawn(2, Vector3(4, 0, 0))])
	var pre: Array = sim.states.map(func(s): return s.position)
	var saw_partial_commit := false
	var saw_out_of_order := false
	sim.compute_hook = func(old: Array, next: Array, i: int) -> void:
		for j in range(i):
			if next[j] == null:
				saw_out_of_order = true
		for k in range(sim.states.size()):
			if sim.states[k].position != pre[k]:
				saw_partial_commit = true
	sim.step([Vector4(1, 0, 0, 0), Vector4(0, 1, 0, 0), Vector4(0, 0, 1, 0)])
	check(not saw_out_of_order, "compute phase runs in stable order")
	check(not saw_partial_commit,
		"no drone observes a partially committed swarm during a step")
	check_eq(sim.step_count, 1, "commit happened once")


func test_all_drones_move_simultaneously() -> void:
	# If updates were sequential, drone 1 would react to drone 0's NEW
	# position. With synchronous semantics both move from the old state.
	var sim := SwarmSimulation.new(SimConfig.new())
	sim.reset([_spawn(0, Vector3.ZERO), _spawn(1, Vector3(1, 0, 0))])
	sim.step([Vector4(1, 0, 0, 0), Vector4(-1, 0, 0, 0)])
	check(sim.states[0].position.x > 0.0, "drone 0 moved +x")
	check(sim.states[1].position.x < 1.0, "drone 1 moved -x")


func test_stable_agent_order_with_deactivation() -> void:
	var sim := SwarmSimulation.new(SimConfig.new())
	sim.reset([_spawn(0, Vector3.ZERO), _spawn(1, Vector3(3, 0, 0), 1e-6),
		_spawn(2, Vector3(6, 0, 0))])
	sim.step([Vector4.ZERO, Vector4.ZERO, Vector4.ZERO])
	check_eq(sim.states.size(), 3, "deactivated drones keep their slot")
	check_eq(sim.states[0].agent_id, 0, "index 0 id")
	check_eq(sim.states[1].agent_id, 1, "index 1 id")
	check_eq(sim.states[2].agent_id, 2, "index 2 id")
	check(not sim.states[1].active, "drained drone deactivated")
	check(sim.states[0].active and sim.states[2].active,
		"other drones stay active")


func test_ground_collision_reported() -> void:
	var sim := SwarmSimulation.new(SimConfig.new())
	var cfg := sim.config
	sim.reset([_spawn(0, Vector3(0, cfg.bounds_min.y + cfg.drone_radius + 0.05, 0))])
	for _i in range(20):
		sim.step([Vector4(0, -1, 0, 0)])  # action y is vertical (Y-up world)
	var s := sim.states[0]
	check(s.collided, "ground contact raises the collision flag")
	check(s.collision_count > 0, "collision steps are counted")
	check(s.position.y >= cfg.bounds_min.y + cfg.drone_radius - 1e-6,
		"drone never penetrates the ground")


func test_obstacle_collision_reported() -> void:
	var sim := SwarmSimulation.new(SimConfig.new())
	var cfg := sim.config
	var box := AABB(Vector3(2, 0, -1), Vector3(1, 4, 2))
	sim.reset([_spawn(0, Vector3(0, 2, 0))], [box])
	for _i in range(20):
		sim.step([Vector4(1, 0, 0, 0)])
	var s := sim.states[0]
	check(s.collided, "flying into an obstacle raises the collision flag")
	check(s.collision_count > 0, "obstacle collisions counted")
	var closest: Vector3 = s.position.clamp(box.position, box.position + box.size)
	check(closest.distance_to(s.position) >= cfg.drone_radius - 1e-4,
		"drone sphere never penetrates the obstacle")


func test_world_bounds_clamped() -> void:
	var sim := SwarmSimulation.new(SimConfig.new())
	var cfg := sim.config
	sim.reset([_spawn(0, Vector3(0, 5, 0))])
	for _i in range(200):
		sim.step([Vector4(1, 0, 0, 0)])
	var s := sim.states[0]
	check(s.position.x <= cfg.bounds_max.x - cfg.drone_radius + 1e-4,
		"drone stays inside world bounds")
	check(s.collided, "hitting the bounds raises the collision flag")


func test_drone_drone_collision_symmetric() -> void:
	var sim := SwarmSimulation.new(SimConfig.new())
	var cfg := sim.config
	# Spawned overlapping (< 2 * radius apart): both must be flagged and
	# pushed apart symmetrically, deterministically.
	sim.reset([_spawn(0, Vector3.ZERO), _spawn(1, Vector3(0.3, 0, 0))])
	sim.step([Vector4.ZERO, Vector4.ZERO])
	var a := sim.states[0]
	var b := sim.states[1]
	check(a.collided and b.collided, "both drones flagged on mutual collision")
	var dist: float = a.position.distance_to(b.position)
	check(dist >= 2.0 * cfg.drone_radius - 1e-4,
		"drones separated to at least 2 * radius")
	check_approx((a.position.x + b.position.x) * 0.5, 0.15, 1e-5,
		"separation preserves the pair centroid")
