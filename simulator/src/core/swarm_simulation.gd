class_name SwarmSimulation
extends RefCounted

## Deterministic swarm simulation core.
##
## Preserves the FSYNC compute-then-commit semantics of the legacy GDST
## DroneManager: within one environment step every drone's next state is
## computed from the SAME old swarm state, all results are validated, and
## only then is the new state committed. No drone can observe a partially
## updated swarm.
##
## This class owns pure simulation state only. It has no Node, no rendering,
## no tweens and no timers, so it advances identically in visual and
## headless mode.

var config: SimConfig
## Committed swarm state. Stable ordering: index == position in the spawn
## list for the whole episode; agent_id never changes.
var states: Array[DroneState] = []
## Previously committed state, kept for render interpolation and rewards.
var prev_states: Array[DroneState] = []
## Static world: ground plane is config.bounds_min.y, plus these AABBs.
var obstacles: Array[AABB] = []
var step_count: int = 0

## Test/instrumentation hook: when set, called as
## hook(old_states, next_states, computing_index) once per drone during the
## compute phase. Must not mutate anything. Used by the compute-before-commit
## test to prove drones observe only the old state.
var compute_hook: Callable = Callable()


func _init(p_config: SimConfig = null) -> void:
	config = p_config if p_config != null else SimConfig.new()


## Starts a new episode from explicit spawn states. Ordering of spawn_states
## defines the stable agent ordering for the episode.
func reset(spawn_states: Array[DroneState], p_obstacles: Array[AABB] = []) -> void:
	states = []
	for s in spawn_states:
		states.append(s.duplicate_state())
	prev_states = []
	for s in states:
		prev_states.append(s.duplicate_state())
	obstacles = p_obstacles.duplicate()
	step_count = 0


func agent_count() -> int:
	return states.size()


func active_count() -> int:
	var n := 0
	for s in states:
		if s.active:
			n += 1
	return n


## Advances the swarm by one environment step.
## actions[i] is the already-validated, already-clamped action for drone i.
## Returns {fail: bool, msg: String}; on failure NOTHING is committed, which
## mirrors the legacy ExecReturn behaviour of aborting the whole step.
func step(actions: Array) -> Dictionary:
	if actions.size() != states.size():
		return {"fail": true,
			"msg": "expected %d actions, got %d" % [states.size(), actions.size()]}

	var old := states
	var next: Array[DroneState] = []
	next.resize(old.size())

	# ---- COMPUTE phase: every drone reads only `old`. ----
	for i in range(old.size()):
		if compute_hook.is_valid():
			compute_hook.call(old, next, i)
		next[i] = DroneDynamics.integrate(old[i], actions[i], config, obstacles)

	# ---- VALIDATE phase: refuse to commit non-finite state. ----
	for i in range(next.size()):
		if not next[i].validate():
			return {"fail": true,
				"msg": "non-finite next state for agent %d" % next[i].agent_id}

	# Drone-drone collisions are resolved between the simultaneously computed
	# candidates (never against a half-committed swarm), symmetrically and in
	# fixed index order so the result is deterministic.
	_resolve_drone_collisions(next)

	# ---- COMMIT phase. ----
	prev_states = old
	states = next
	step_count += 1
	return {"fail": false, "msg": ""}


## Sphere-sphere resolution between candidate next states. Overlapping pairs
## are flagged and pushed apart symmetrically along their separation axis.
func _resolve_drone_collisions(next: Array[DroneState]) -> void:
	var min_dist: float = 2.0 * config.drone_radius
	var min_dist_sq: float = min_dist * min_dist
	for i in range(next.size()):
		if not next[i].active:
			continue
		for j in range(i + 1, next.size()):
			if not next[j].active:
				continue
			var delta := next[j].position - next[i].position
			var dist_sq := delta.length_squared()
			if dist_sq >= min_dist_sq:
				continue
			next[i].collided = true
			next[j].collided = true
			var n: Vector3
			var dist: float
			if dist_sq > 1e-12:
				dist = sqrt(dist_sq)
				n = delta / dist
			else:
				# Perfect overlap: deterministic arbitrary axis from ids.
				n = Vector3.RIGHT
				dist = 0.0
			var push: Vector3 = n * (0.5 * (min_dist - dist))
			next[i].position -= push
			next[j].position += push
			# Remove approaching velocity components, symmetrically.
			var vi: float = next[i].velocity.dot(n)
			var vj: float = next[j].velocity.dot(n)
			if vi > 0.0:
				next[i].velocity -= n * vi
			if vj < 0.0:
				next[j].velocity -= n * vj


## Packed snapshot of the full logical state, used by determinism tests and
## by the headless runner to hash trajectories.
func snapshot_packed() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for s in states:
		out.append_array(s.to_packed_float32())
	return out
