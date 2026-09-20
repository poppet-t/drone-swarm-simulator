class_name ObservationV2
extends RefCounted

## Research observation contract, version 2 (frozen; see docs/observation_v2.md).
##
## One contiguous Float32 vector per agent, structured into named blocks that
## are also exposed as a logical dictionary (build_structured) so tests and the
## dataset layer can convert between both representations losslessly.
##
## Design invariants:
##   * Pure function of the committed simulation state (+ scenario mission
##     state): same seed and actions => identical vector, always finite.
##   * Interacts ONLY with logical geometry (AABB obstacles, bounds, ground
##     plane, communication shadows) — never rendered mesh data.
##   * Inactive agents return an all-zero row (own.active flag 0, all masks 0,
##     ranges 0 = "no data"); consumers must respect the mask fields.
##   * Neighbours are ordered by (distance, then agent_id) and capped at
##     K_NEIGHBOURS entries with a valid mask per slot.

const VERSION := 2

# ---- Block sizes -----------------------------------------------------------
const OWN_SIZE := 17
const MISSION_SIZE := 7
const RAY_COUNT := 16
const K_NEIGHBOURS := 6
const NB_FIELDS := 11 # rel_pos 3 | rel_vel 3 | rel_yaw 2 | quality | age | mask
const NEIGHBOURS_SIZE := K_NEIGHBOURS * NB_FIELDS
const COMM_SIZE := 5
const TOTAL_SIZE := OWN_SIZE + MISSION_SIZE + RAY_COUNT + NEIGHBOURS_SIZE \
	+ COMM_SIZE

# ---- Block offsets ---------------------------------------------------------
const OWN_OFFSET := 0
const MISSION_OFFSET := OWN_OFFSET + OWN_SIZE
const RANGE_OFFSET := MISSION_OFFSET + MISSION_SIZE
const NEIGHBOURS_OFFSET := RANGE_OFFSET + RAY_COUNT
const COMM_OFFSET := NEIGHBOURS_OFFSET + NEIGHBOURS_SIZE

# ---- Own-state field offsets (within block A) ------------------------------
const OWN_POS := 0          # 0..2 normalized position [-1, 1]
const OWN_VEL := 3          # 3..5 velocity / max_speed [-1, 1]
const OWN_YAW_SIN := 6      # sin(yaw)
const OWN_YAW_COS := 7      # cos(yaw)
const OWN_YAW_RATE := 8     # yaw_rate / max_yaw_rate [-1, 1]
const OWN_BATTERY := 9      # battery [0, 1]
const OWN_COLLIDED := 10    # collided flag {0, 1}
const OWN_PREV_ACTION := 11 # 11..14 clamped previous action [-1, 1]^4
const OWN_ACTIVE := 15      # active flag {0, 1}
const OWN_TIME := 16        # step_count / max_episode_steps [0, 1]

# ---- Mission-state field offsets (within block B) --------------------------
const M_GOAL_VEC := 0    # 17..19 (goal - position) / world_diag
const M_GOAL_DIST := 3   # 20 distance(goal, position) / world_diag
const M_PROGRESS := 4    # 21 scenario-defined mission progress [0, 1]
const M_PHASE := 5       # 22 phase_code / max(max_phase_count, 1) [0, 1]
const M_SUCCESS := 6     # 23 local success flag {0, 1}

# ---- Communication self-state field offsets (within block E) ---------------
const C_VALID := 0   # 106 own radio validity {0, 1} (1 while active)
const C_QUALITY := 1 # 107 mean neighbour link quality [0, 1] (0 if none)
const C_AGE := 2     # 108 normalized message age [0, 1] (0 = synchronous)
const C_LOSS := 3    # 109 packet-loss indicator [0, 1] (0 = none simulated)
const C_NB_COUNT := 4 # 110 active neighbour count / K_NEIGHBOURS [0, 1]

# Range sensor reach in meters; samples are hit_distance / RANGE_MAX_M so
# free space reads 1.0 and a surface touching the sphere reads ~drone_radius.
const RANGE_MAX_M := 20.0

# Message age normalization ceiling in policy steps. The synchronous
# simulator reports age 0; the bound exists so future asynchronous execution
# can populate the same field without changing the layout.
const MAX_MESSAGE_AGE_STEPS := 50


## Named-field layout published through GET_SPEC under
## "observation_layouts"]["2"]. Offsets are absolute indices into the flat
## per-agent vector; every entry documents length and value bounds.
static func layout() -> Dictionary:
	return {
		"version": VERSION,
		"size_per_agent": TOTAL_SIZE,
		"dtype": "float32",
		"blocks": {
			"own_state": {"offset": OWN_OFFSET, "length": OWN_SIZE},
			"mission": {"offset": MISSION_OFFSET, "length": MISSION_SIZE},
			"range_sensor": {"offset": RANGE_OFFSET, "length": RAY_COUNT},
			"neighbours": {"offset": NEIGHBOURS_OFFSET,
				"length": NEIGHBOURS_SIZE,
				"count": K_NEIGHBOURS, "fields_per_neighbour": NB_FIELDS},
			"communication_self": {"offset": COMM_OFFSET, "length": COMM_SIZE},
		},
		"own_state_fields": {
			"position_norm": {"offset": 0, "length": 3, "min": -1.0, "max": 1.0},
			"velocity_norm": {"offset": 3, "length": 3, "min": -1.0, "max": 1.0},
			"yaw_sin": {"offset": 6, "length": 1, "min": -1.0, "max": 1.0},
			"yaw_cos": {"offset": 7, "length": 1, "min": -1.0, "max": 1.0},
			"yaw_rate_norm": {"offset": 8, "length": 1, "min": -1.0, "max": 1.0},
			"battery": {"offset": 9, "length": 1, "min": 0.0, "max": 1.0},
			"collided": {"offset": 10, "length": 1, "min": 0.0, "max": 1.0},
			"previous_action": {"offset": 11, "length": 4, "min": -1.0, "max": 1.0},
			"active": {"offset": 15, "length": 1, "min": 0.0, "max": 1.0},
			"time_fraction": {"offset": 16, "length": 1, "min": 0.0, "max": 1.0},
		},
		"mission_fields": {
			"goal_vec_norm": {"offset": 17, "length": 3},
			"goal_dist_norm": {"offset": 20, "length": 1},
			"progress": {"offset": 21, "length": 1, "min": 0.0, "max": 1.0},
			"phase_code_norm": {"offset": 22, "length": 1, "min": 0.0, "max": 1.0},
			"success": {"offset": 23, "length": 1, "min": 0.0, "max": 1.0},
		},
		"range_sensor": {
			"offset": RANGE_OFFSET, "length": RAY_COUNT, "min": 0.0, "max": 1.0,
			"rays": RAY_COUNT, "pattern": "horizontal, drone-local frame",
			"normalization": "hit_distance_m / %.1f" % RANGE_MAX_M,
			"zero_means": "no data (inactive row)",
		},
		"neighbour_fields": {
			"rel_position_norm": {"offset": 40, "length": 3},
			"rel_velocity_norm": {"offset": 43, "length": 3},
			"rel_yaw_sin": {"offset": 46, "length": 1},
			"rel_yaw_cos": {"offset": 47, "length": 1},
			"link_quality": {"offset": 48, "length": 1, "min": 0.0, "max": 1.0},
			"message_age_norm": {"offset": 49, "length": 1, "min": 0.0, "max": 1.0},
			"valid_mask": {"offset": 50, "length": 1, "min": 0.0, "max": 1.0},
			"ordering": "ascending (distance, then agent_id)",
		},
		"communication_self_fields": {
			"validity": {"offset": 106, "length": 1},
			"quality_mean": {"offset": 107, "length": 1, "min": 0.0, "max": 1.0},
			"staleness": {"offset": 108, "length": 1, "min": 0.0, "max": 1.0},
			"packet_loss": {"offset": 109, "length": 1, "min": 0.0, "max": 1.0},
			"active_neighbour_fraction": {"offset": 110, "length": 1,
				"min": 0.0, "max": 1.0},
		},
	}


# ------------------------------------------------------------------ building

## Logical, human-readable form of one agent's observation. Keys mirror the
## named blocks; flatten(structured) reproduces the flat vector exactly.
func _init() -> void:
	push_error("ObservationV2 is static-only; do not instantiate")


static func zero_row() -> PackedFloat32Array:
	var row := PackedFloat32Array()
	row.resize(TOTAL_SIZE)
	return row


static func build_structured(sim: SwarmSimulation, scenario: Scenario,
		config: SimConfig, comm_shadows: Array) -> Array:
	var diag: float = config.bounds_min.distance_to(config.bounds_max)
	var max_steps: int = maxi(scenario.max_episode_steps(), 1)
	var time_fraction: float = clampf(float(sim.step_count) / float(max_steps),
		0.0, 1.0)
	var out: Array = []
	out.resize(sim.states.size())
	for i in range(sim.states.size()):
		var s: DroneState = sim.states[i]
		if not s.active:
			out[i] = _zero_structured()
			continue
		var centre: Vector3 = (config.bounds_min + config.bounds_max) * 0.5
		var half: Vector3 = (config.bounds_max - config.bounds_min) * 0.5
		var own := PackedFloat32Array()
		own.resize(OWN_SIZE)
		own[OWN_POS + 0] = (s.position.x - centre.x) / half.x
		own[OWN_POS + 1] = (s.position.y - centre.y) / half.y
		own[OWN_POS + 2] = (s.position.z - centre.z) / half.z
		own[OWN_VEL + 0] = s.velocity.x / config.max_speed
		own[OWN_VEL + 1] = s.velocity.y / config.max_speed
		own[OWN_VEL + 2] = s.velocity.z / config.max_speed
		own[OWN_YAW_SIN] = sin(s.yaw)
		own[OWN_YAW_COS] = cos(s.yaw)
		own[OWN_YAW_RATE] = s.yaw_rate / config.max_yaw_rate
		own[OWN_BATTERY] = s.battery
		own[OWN_COLLIDED] = 1.0 if s.collided else 0.0
		own[OWN_PREV_ACTION + 0] = s.previous_action.x
		own[OWN_PREV_ACTION + 1] = s.previous_action.y
		own[OWN_PREV_ACTION + 2] = s.previous_action.z
		own[OWN_PREV_ACTION + 3] = s.previous_action.w
		own[OWN_ACTIVE] = 1.0
		own[OWN_TIME] = time_fraction

		var mission: Dictionary = scenario.build_mission_v2(sim, i)
		var mb := PackedFloat32Array()
		mb.resize(MISSION_SIZE)
		var goal: Vector3 = mission.get("goal", Vector3.ZERO)
		var rel: Vector3 = goal - s.position
		mb[M_GOAL_VEC + 0] = rel.x / diag
		mb[M_GOAL_VEC + 1] = rel.y / diag
		mb[M_GOAL_VEC + 2] = rel.z / diag
		mb[M_GOAL_DIST] = rel.length() / diag
		mb[M_PROGRESS] = clampf(float(mission.get("progress", 0.0)), 0.0, 1.0)
		var phases: float = maxf(float(mission.get("max_phase_count", 1.0)), 1.0)
		mb[M_PHASE] = clampf(float(mission.get("phase_code", 0.0)) / phases, 0.0, 1.0)
		mb[M_SUCCESS] = 1.0 if bool(mission.get("success", false)) else 0.0

		var rays := PackedFloat32Array()
		rays.resize(RAY_COUNT)
		for k in range(RAY_COUNT):
			var angle := TAU * float(k) / float(RAY_COUNT)
			var dir := Vector3.RIGHT.rotated(Vector3.UP, s.yaw + angle)
			rays[k] = cast_ray(s.position, dir, config, sim.obstacles)

		var nb_list := _ordered_neighbours(sim, i)
		var neighbours: Array = []
		var quality_sum := 0.0
		while neighbours.size() < K_NEIGHBOURS:
			neighbours.append(_empty_neighbour())
		for j in range(mini(nb_list.size(), K_NEIGHBOURS)):
			var other_idx: int = nb_list[j][0]
			var o: DroneState = sim.states[other_idx]
			var d_vec: Vector3 = o.position - s.position
			var q: float = link_quality(s.position, o.position, config,
				comm_shadows)
			quality_sum += q
			var rel_yaw: float = wrapf(o.yaw - s.yaw, -PI, PI)
			neighbours[j] = {
				"agent_id": o.agent_id,
				"rel_position": [d_vec.x / diag, d_vec.y / diag, d_vec.z / diag],
				"rel_velocity": [o.velocity.x / config.max_speed,
					o.velocity.y / config.max_speed,
					o.velocity.z / config.max_speed],
				"rel_yaw": [sin(rel_yaw), cos(rel_yaw)],
				"link_quality": q,
				# Synchronous stepping observes current state: age zero. The
				# field keeps its slot for future asynchronous execution.
				"message_age": 0.0,
				"valid": 1.0,
			}

		var comm := PackedFloat32Array()
		comm.resize(COMM_SIZE)
		comm[C_VALID] = 1.0
		comm[C_QUALITY] = 0.0 if nb_list.is_empty() \
			else quality_sum / float(nb_list.size())
		comm[C_AGE] = 0.0
		comm[C_LOSS] = 0.0
		comm[C_NB_COUNT] = float(nb_list.size()) / float(K_NEIGHBOURS)

		out[i] = {
			"agent_id": s.agent_id,
			"own_state": own,
			"mission": mb,
			"range_sensor": rays,
			"neighbours": neighbours,
			"communication_self": comm,
		}
	return out


## Flat Float32 vector per agent — the wire/training representation.
static func build_flat(sim: SwarmSimulation, scenario: Scenario,
		config: SimConfig, comm_shadows: Array) -> Array:
	var structured := build_structured(sim, scenario, config, comm_shadows)
	var out: Array = []
	out.resize(structured.size())
	for i in range(structured.size()):
		out[i] = flatten(structured[i])
	return out


## Packs one structured observation into its contiguous Float32 layout.
## Inverse-tested: flatten(x) round-trips every field of build_structured.
static func flatten(structured: Dictionary) -> PackedFloat32Array:
	if structured.is_empty():
		return zero_row()
	var row := PackedFloat32Array()
	row.resize(TOTAL_SIZE)
	_write_block(row, OWN_OFFSET, structured["own_state"])
	_write_block(row, MISSION_OFFSET, structured["mission"])
	_write_block(row, RANGE_OFFSET, structured["range_sensor"])
	var neighbours: Array = structured["neighbours"]
	for j in range(mini(neighbours.size(), K_NEIGHBOURS)):
		var n: Dictionary = neighbours[j]
		var base := NEIGHBOURS_OFFSET + j * NB_FIELDS
		row[base + 0] = n["rel_position"][0]
		row[base + 1] = n["rel_position"][1]
		row[base + 2] = n["rel_position"][2]
		row[base + 3] = n["rel_velocity"][0]
		row[base + 4] = n["rel_velocity"][1]
		row[base + 5] = n["rel_velocity"][2]
		row[base + 6] = n["rel_yaw"][0]
		row[base + 7] = n["rel_yaw"][1]
		row[base + 8] = n["link_quality"]
		row[base + 9] = n["message_age"]
		row[base + 10] = n["valid"]
	_write_block(row, COMM_OFFSET, structured["communication_self"])
	return row


static func _write_block(row: PackedFloat32Array, offset: int,
		block: PackedFloat32Array) -> void:
	for k in range(block.size()):
		row[offset + k] = block[k]


static func _zero_structured() -> Dictionary:
	var zeros_own := PackedFloat32Array()
	zeros_own.resize(OWN_SIZE)
	var zeros_mission := PackedFloat32Array()
	zeros_mission.resize(MISSION_SIZE)
	var zeros_range := PackedFloat32Array()
	zeros_range.resize(RAY_COUNT)
	var zeros_comm := PackedFloat32Array()
	zeros_comm.resize(COMM_SIZE)
	var empty: Array = []
	for _j in range(K_NEIGHBOURS):
		empty.append(_empty_neighbour())
	return {
		"agent_id": -1,
		"own_state": zeros_own,
		"mission": zeros_mission,
		"range_sensor": zeros_range,
		"neighbours": empty,
		"communication_self": zeros_comm,
	}


static func _empty_neighbour() -> Dictionary:
	return {
		"agent_id": -1,
		"rel_position": [0.0, 0.0, 0.0],
		"rel_velocity": [0.0, 0.0, 0.0],
		"rel_yaw": [0.0, 0.0],
		"link_quality": 0.0,
		"message_age": 0.0,
		"valid": 0.0,
	}


## Active neighbours sorted by (distance, then agent_id) — stable ordering.
static func _ordered_neighbours(sim: SwarmSimulation, index: int) -> Array:
	var origin: Vector3 = sim.states[index].position
	var candidates: Array = []
	for j in range(sim.states.size()):
		if j == index or not sim.states[j].active:
			continue
		candidates.append([origin.distance_squared_to(sim.states[j].position),
			sim.states[j].agent_id, j])
	candidates.sort_custom(func(a, b):
		if a[0] < b[0]:
			return true
		if a[0] > b[0]:
			return false
		return a[1] < b[1])
	return candidates


## Deterministic pairwise link quality in [0, 1]: linear decay over
## radio_range, attenuated by shadow regions intersecting the segment.
static func link_quality(a: Vector3, b: Vector3, config: SimConfig,
		shadows: Array) -> float:
	var dist: float = a.distance_to(b)
	if dist >= config.radio_range:
		return 0.0
	var q: float = 1.0 - dist / config.radio_range
	if segment_intersects_any_aabb(a, b, shadows):
		q *= config.shadow_attenuation
	return clampf(q, 0.0, 1.0)


## Slab-method segment/AABB intersection (branch-and-bound free, exact).
static func segment_intersects_any_aabb(a: Vector3, b: Vector3,
		boxes: Array) -> bool:
	for box_v in boxes:
		var box: AABB = box_v
		if _segment_hits_aabb(a, b, box.position, box.position + box.size):
			return true
	return false


static func _segment_hits_aabb(p0: Vector3, p1: Vector3,
		bmin: Vector3, bmax: Vector3) -> bool:
	var d := p1 - p0
	var tmin := 0.0
	var tmax := 1.0
	for axis in range(3):
		var o := p0[axis]
		var dd := d[axis]
		if absf(dd) < 1e-9:
			if o < bmin[axis] or o > bmax[axis]:
				return false
		else:
			var inv := 1.0 / dd
			var t0 := (bmin[axis] - o) * inv
			var t1 := (bmax[axis] - o) * inv
			if t0 > t1:
				var tmp := t0
				t0 = t1
				t1 = tmp
			tmin = maxf(tmin, t0)
			tmax = minf(tmax, t1)
			if tmin > tmax:
				return false
	return true


## Deterministic analytic ray march against the LOGICAL world: AABB slabs,
## ground plane, world side walls and ceiling. Returns the normalized hit
## distance in (0, 1]; 1.0 means nothing within RANGE_MAX_M.
static func cast_ray(origin: Vector3, dir: Vector3, config: SimConfig,
		obstacles: Array) -> float:
	var best := RANGE_MAX_M
	# Ground plane (bounds_min.y) and ceiling (bounds_max.y).
	if absf(dir.y) > 1e-9:
		var t_ground := (config.bounds_min.y - origin.y) / dir.y
		if t_ground > 1e-6 and t_ground < best:
			best = t_ground
		var t_ceiling := (config.bounds_max.y - origin.y) / dir.y
		if t_ceiling > 1e-6 and t_ceiling < best:
			best = t_ceiling
	# Vertical side walls of the world box.
	if absf(dir.x) > 1e-9:
		for wall_x in [config.bounds_min.x, config.bounds_max.x]:
			var t := (wall_x - origin.x) / dir.x
			if t > 1e-6 and t < best:
				best = t
	if absf(dir.z) > 1e-9:
		for wall_z in [config.bounds_min.z, config.bounds_max.z]:
			var t := (wall_z - origin.z) / dir.z
			if t > 1e-6 and t < best:
				best = t
	# Obstacle AABBs (slab method against a long segment).
	var far := origin + dir * (RANGE_MAX_M * 2.0)
	for box_v in obstacles:
		var box: AABB = box_v
		var t_hit := _ray_aabb_distance(origin, far, box)
		if t_hit >= 0.0 and t_hit < best:
			best = t_hit
	return clampf(best / RANGE_MAX_M, 0.0, 1.0)


## Entry distance along segment origin->far into the box, or -1 if missed.
static func _ray_aabb_distance(origin: Vector3, far: Vector3,
		box: AABB) -> float:
	var d := far - origin
	var tmin := 0.0
	var tmax := 1.0
	for axis in range(3):
		var o := origin[axis]
		var dd := d[axis]
		if absf(dd) < 1e-9:
			if o < box.position[axis] or o > box.position[axis] + box.size[axis]:
				return -1.0
		else:
			var inv := 1.0 / dd
			var t0 := (box.position[axis] - o) * inv
			var t1 := (box.position[axis] + box.size[axis] - o) * inv
			if t0 > t1:
				var tmp := t0
				t0 = t1
				t1 = tmp
			tmin = maxf(tmin, t0)
			tmax = minf(tmax, t1)
			if tmin > tmax:
				return -1.0
	return tmin * d.length()
