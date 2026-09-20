class_name DroneDynamics
extends RefCounted

## Deterministic high-level drone dynamics.
##
## Phase 1 deliberately does NOT simulate raw rotor physics. One action is a
## normalized [ax, ay, az, yaw_rate] command in [-1, 1]^4, interpreted as a
## world-relative desired acceleration (with hover compensation, so az = 0
## holds altitude) plus a desired yaw rate. Integration is semi-implicit
## Euler at SimConfig.physics_dt with SimConfig.physics_substeps substeps per
## environment step.
##
## Static-world collision (ground plane, AABB obstacles, world bounds) is
## resolved analytically against the drone sphere each substep, so results
## never depend on the physics-server flush or the rendered frame rate.
## Drone-drone collisions are handled by SwarmSimulation so that every drone
## is resolved against the same simultaneous state.

const ACTION_SIZE := 4


## Clamps a raw action into [-1, 1]^4. Callers must reject non-finite
## actions before calling this (see SwarmEnv.apply_actions).
static func clamp_action(raw: PackedFloat32Array) -> Vector4:
	return Vector4(
		clampf(raw[0], -1.0, 1.0),
		clampf(raw[1], -1.0, 1.0),
		clampf(raw[2], -1.0, 1.0),
		clampf(raw[3], -1.0, 1.0))


## Returns true when the action has the right shape and only finite values.
static func action_is_valid(raw: PackedFloat32Array) -> bool:
	if raw.size() != ACTION_SIZE:
		return false
	for v in raw:
		if not is_finite(v):
			return false
	return true


## Integrates one drone for one full environment step (all substeps) against
## the static world. Returns a NEW DroneState; the input is never mutated,
## which is what allows the swarm to compute every drone from the same old
## state before committing. Inactive drones are returned unchanged except
## for the cleared per-step collision flag.
static func integrate(old: DroneState, action: Vector4, config: SimConfig,
		obstacles: Array) -> DroneState:
	var s := old.duplicate_state()
	s.collided = false
	s.previous_action = action
	if not s.active:
		return s

	var dt: float = config.physics_dt
	var radius: float = config.drone_radius
	var ground_y: float = config.bounds_min.y

	for _i in range(config.physics_substeps):
		# Commanded acceleration; with hover compensation gravity is cancelled
		# by the flight controller and never enters the integrator.
		var accel := Vector3(action.x, action.y, action.z) * config.max_accel
		if not config.hover_compensated:
			accel.y -= config.gravity
		accel -= config.linear_drag * s.velocity

		# Semi-implicit Euler: velocity first, then position.
		s.velocity += accel * dt
		if s.velocity.length() > config.max_speed:
			s.velocity = s.velocity.normalized() * config.max_speed

		s.yaw_rate = action.w * config.max_yaw_rate
		s.yaw = wrapf(s.yaw + s.yaw_rate * dt, -PI, PI)
		s.position += s.velocity * dt

		_resolve_static_collisions(s, config, obstacles, radius, ground_y)

	# Battery drains with time and effort; empty battery deactivates the drone.
	var effort: float = Vector3(action.x, action.y, action.z).length() / sqrt(3.0)
	s.battery = maxf(0.0, s.battery -
		(config.battery_base_rate + config.battery_accel_rate * effort) * config.policy_dt)
	if s.battery <= 0.0:
		s.active = false

	if s.collided:
		s.collision_count += 1
	return s


## Sphere-vs-static-world resolution. Mutates s in place: position is pushed
## out of penetration, the velocity component into the surface is removed,
## and the per-step collision flag is raised.
static func _resolve_static_collisions(s: DroneState, config: SimConfig,
		obstacles: Array, radius: float, ground_y: float) -> void:
	# Ground plane.
	if s.position.y - radius < ground_y:
		s.position.y = ground_y + radius
		if s.velocity.y < 0.0:
			s.velocity.y = 0.0
		s.collided = true

	# AABB obstacles: push out along the axis of least penetration.
	for box in obstacles:
		var aabb: AABB = box
		var closest := s.position.clamp(aabb.position, aabb.position + aabb.size)
		var delta := s.position - closest
		var dist_sq := delta.length_squared()
		if dist_sq >= radius * radius:
			continue
		s.collided = true
		if dist_sq > 1e-12:
			var n := delta / sqrt(dist_sq)
			s.position = closest + n * radius
			var vn: float = s.velocity.dot(n)
			if vn < 0.0:
				s.velocity -= n * vn
		else:
			# Center inside the box: eject along the least-penetration axis.
			var local := s.position - aabb.get_center()
			var half := aabb.size * 0.5
			var pen := half - local.abs()
			if pen.x <= pen.y and pen.x <= pen.z:
				var sign_x := 1.0 if local.x >= 0.0 else -1.0
				s.position.x = aabb.get_center().x + sign_x * (half.x + radius)
				s.velocity.x = 0.0
			elif pen.y <= pen.z:
				var sign_y := 1.0 if local.y >= 0.0 else -1.0
				s.position.y = aabb.get_center().y + sign_y * (half.y + radius)
				s.velocity.y = 0.0
			else:
				var sign_z := 1.0 if local.z >= 0.0 else -1.0
				s.position.z = aabb.get_center().z + sign_z * (half.z + radius)
				s.velocity.z = 0.0

	# World bounds: clamp and kill the outward velocity component.
	var min_b: Vector3 = config.bounds_min
	var max_b: Vector3 = config.bounds_max
	var clamped := s.position.clamp(min_b + Vector3.ONE * radius,
		max_b - Vector3.ONE * radius)
	if clamped != s.position:
		if clamped.x != s.position.x:
			s.velocity.x = 0.0
		if clamped.y != s.position.y:
			s.velocity.y = 0.0
		if clamped.z != s.position.z:
			s.velocity.z = 0.0
		s.position = clamped
		s.collided = true
