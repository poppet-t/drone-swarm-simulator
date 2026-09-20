class_name WaypointScenario
extends Scenario

## Phase 1 scenario: one or more drones must each reach the shared 3D target.
##
## A drone that reaches the target lands (active = false), which gives the
## environment a variable active-agent count. The episode terminates when no
## active drones remain and truncates after max_steps environment steps.
## All randomness (spawn positions, target, obstacle jitter) comes from the
## seeded RNG passed to setup().

const OBS_SIZE := 23
const SUCCESS_RADIUS := 0.75
const SUCCESS_BONUS := 10.0
const COLLISION_PENALTY := 1.0
const TIME_PENALTY := 0.01

var target: Vector3 = Vector3.ZERO
var max_steps: int = 500
var _successes: int = 0
var _prev_dist: PackedFloat32Array = PackedFloat32Array()
## Distance from spawn position to the target at reset; anchors the mission
## progress term of observation version 2.
var _start_dist: PackedFloat32Array = PackedFloat32Array()

func _init() -> void:
	scenario_name = "waypoint"


func setup(rng: RandomNumberGenerator, agent_count: int,
		config: SimConfig) -> Dictionary:
	var center := (config.bounds_min + config.bounds_max) * 0.5
	center.y = config.bounds_min.y

	# Seeded target: above ground, away from the walls.
	target = Vector3(
		rng.randf_range(config.bounds_min.x + 5.0, config.bounds_max.x - 5.0),
		rng.randf_range(3.0, 8.0),
		rng.randf_range(config.bounds_min.z + 5.0, config.bounds_max.z - 5.0))

	# Seeded spawn ring near the ground, around the world center.
	var spawn_states: Array[DroneState] = []
	for i in range(agent_count):
		var s := DroneState.new()
		s.agent_id = i
		s.position = Vector3(
			center.x + rng.randf_range(-4.0, 4.0),
			config.bounds_min.y + config.drone_radius + rng.randf_range(0.0, 2.0),
			center.z + rng.randf_range(-4.0, 4.0))
		s.yaw = rng.randf_range(-PI, PI)
		spawn_states.append(s)

	# Static obstacles: two box pillars between the spawn area and the walls,
	# with seeded jitter so obstacle randomization follows the reset seed.
	var obstacles: Array[AABB] = []
	var pillar_size := Vector3(1.5, 6.0, 1.5)
	for base_x in [-8.0, 8.0]:
		var pos := Vector3(
			base_x + rng.randf_range(-1.5, 1.5),
			config.bounds_min.y,
			rng.randf_range(-6.0, 6.0))
		obstacles.append(AABB(pos, pillar_size))

	_successes = 0
	_prev_dist = PackedFloat32Array()
	_start_dist = PackedFloat32Array()
	for s in spawn_states:
		var d: float = s.position.distance_to(target)
		_prev_dist.append(d)
		_start_dist.append(d)
	return {"states": spawn_states, "obstacles": obstacles}


func build_observations(sim: SwarmSimulation) -> Array:
	var out: Array = []
	var diag: float = _world_diag(sim.config)
	var center := (sim.config.bounds_min + sim.config.bounds_max) * 0.5
	var half := (sim.config.bounds_max - sim.config.bounds_min) * 0.5

	for i in range(sim.states.size()):
		var s := sim.states[i]
		var obs := PackedFloat32Array()
		obs.resize(OBS_SIZE)
		# Normalized position, centered on the world.
		obs[0] = (s.position.x - center.x) / half.x
		obs[1] = (s.position.y - center.y) / half.y
		obs[2] = (s.position.z - center.z) / half.z
		# Normalized velocity.
		obs[3] = s.velocity.x / sim.config.max_speed
		obs[4] = s.velocity.y / sim.config.max_speed
		obs[5] = s.velocity.z / sim.config.max_speed
		# Yaw as (sin, cos) to avoid the wrap discontinuity.
		obs[6] = sin(s.yaw)
		obs[7] = cos(s.yaw)
		# Target relation.
		var rel := target - s.position
		obs[8] = rel.x / diag
		obs[9] = rel.y / diag
		obs[10] = rel.z / diag
		obs[11] = rel.length() / diag
		# Flags and internal state.
		obs[12] = 1.0 if s.collided else 0.0
		obs[13] = s.battery
		obs[14] = s.previous_action.x
		obs[15] = s.previous_action.y
		obs[16] = s.previous_action.z
		obs[17] = s.previous_action.w
		obs[18] = 1.0 if s.active else 0.0
		# Minimal nearest-neighbour representation (relative position and
		# distance); zeros and 1.0 when no other active drone exists.
		var nn := _nearest_neighbour(sim, i)
		if nn >= 0:
			var rel_nn: Vector3 = sim.states[nn].position - s.position
			obs[19] = rel_nn.x / diag
			obs[20] = rel_nn.y / diag
			obs[21] = rel_nn.z / diag
			obs[22] = rel_nn.length() / diag
		else:
			obs[22] = 1.0
		out.append(obs)
	return out


func compute_rewards(sim: SwarmSimulation) -> PackedFloat32Array:
	var rewards := PackedFloat32Array()
	rewards.resize(sim.states.size())
	for i in range(sim.states.size()):
		var s := sim.states[i]
		if not s.active:
			rewards[i] = 0.0
			continue
		var dist: float = s.position.distance_to(target)
		var r: float = _prev_dist[i] - dist - TIME_PENALTY
		if s.collided:
			r -= COLLISION_PENALTY
		if dist <= SUCCESS_RADIUS:
			r += SUCCESS_BONUS
			# Landing: reached drones leave the active set.
			s.active = false
			s.velocity = Vector3.ZERO
			_successes += 1
		_prev_dist[i] = dist
		rewards[i] = r
	return rewards


func is_terminated(sim: SwarmSimulation) -> bool:
	return sim.active_count() == 0


func is_truncated(sim: SwarmSimulation) -> bool:
	return sim.step_count >= max_steps


func max_episode_steps() -> int:
	return max_steps


## Mission v2: navigate to the shared target; phase 0 = navigating, phase 1 =
## landed/success. Progress is normalized remaining distance from spawn.
func build_mission_v2(sim: SwarmSimulation, index: int) -> Dictionary:
	var s := sim.states[index]
	var dist := s.position.distance_to(target)
	var start_dist: float = _start_dist[index]
	var progress := 0.0
	if start_dist > 1e-6:
		progress = clampf(1.0 - dist / start_dist, 0.0, 1.0)
	var landed := not s.active or dist <= SUCCESS_RADIUS
	return {
		"goal": target,
		"progress": progress,
		"phase_code": 1.0 if landed else 0.0,
		"max_phase_count": 2.0,
		"success": landed,
	}


func get_spec(config: SimConfig, agent_count: int) -> Dictionary:
	return {
		"scenario": scenario_name,
		"agent_count": agent_count,
		"obs_size": OBS_SIZE,
		"action_size": DroneDynamics.ACTION_SIZE,
		"action_low": -1.0,
		"action_high": 1.0,
		"policy_dt": config.policy_dt,
		"max_steps": max_steps,
		"obs_layout": {
			"position": 0, "velocity": 3, "yaw_sin_cos": 6,
			"rel_target": 8, "dist_target": 11, "collided": 12,
			"battery": 13, "previous_action": 14, "active": 18,
			"nearest_neighbour": 19, "nearest_neighbour_dist": 22,
		},
	}


func get_info(sim: SwarmSimulation) -> Dictionary:
	var collisions := 0
	var dist_sum := 0.0
	for s in sim.states:
		collisions += s.collision_count
		dist_sum += s.position.distance_to(target)
	var n: float = maxf(1.0, float(sim.states.size()))
	return {
		"steps": sim.step_count,
		"successes": _successes,
		"active": sim.active_count(),
		"collisions": collisions,
		"mean_distance_to_target": dist_sum / n,
		"target": target,
	}


func _nearest_neighbour(sim: SwarmSimulation, index: int) -> int:
	var best := -1
	var best_sq := INF
	var origin: Vector3 = sim.states[index].position
	for j in range(sim.states.size()):
		if j == index or not sim.states[j].active:
			continue
		var d_sq: float = origin.distance_squared_to(sim.states[j].position)
		if d_sq < best_sq:
			best_sq = d_sq
			best = j
	return best


func _world_diag(config: SimConfig) -> float:
	return config.bounds_min.distance_to(config.bounds_max)
