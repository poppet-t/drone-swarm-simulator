class_name SimConfig
extends RefCounted

## Configuration for the deterministic swarm simulation core.
## All tunables of the dynamics live here so a training run can be fully
## described by one object (and later serialized to JSON for Julia).

## Physics integration timestep (s). Fixed: 60 Hz.
var physics_dt: float = 1.0 / 60.0
## Policy timestep (s): one environment step applies one action for this long.
var policy_dt: float = 1.0 / 20.0
## Physics substeps executed per environment step.
## Invariant: physics_dt * physics_substeps == policy_dt.
var physics_substeps: int = 3

## Maximum commanded acceleration (m/s^2) for action component +/-1.
var max_accel: float = 6.0
## Hard speed limit (m/s); velocity is clamped to this magnitude.
var max_speed: float = 6.0
## Maximum yaw rate (rad/s) for action component +/-1.
var max_yaw_rate: float = PI
## Linear drag coefficient (1/s), applied as accel -= drag * velocity.
var linear_drag: float = 0.8
## Gravity (m/s^2). With hover compensation enabled the policy commands
## acceleration offsets from hover and gravity never reaches the integrator.
var gravity: float = 9.8
## When true, gravity is fully compensated by the flight controller:
## action z = 0 means "hold altitude". Phase 1 keeps this on so the policy
## does not need to learn basic flight stabilization.
var hover_compensated: bool = true

## Battery: fraction drained per second at rest and at full acceleration.
var battery_base_rate: float = 1.0 / 600.0
var battery_accel_rate: float = 1.0 / 300.0

## Drone collision radius (m), sphere used for world and drone-drone checks.
var drone_radius: float = 0.25

## World bounds: drones outside are clamped, flagged and can be reset by the
## scenario. The ground plane is bounds.min.y (0 by default).

## --- Communication model (used by observation version 2) ---
## Radio range in meters for pairwise link quality: quality decays linearly
## from 1.0 at 0 m to 0.0 at radio_range.
var radio_range: float = 30.0
## Multiplier applied to link quality when the straight-line segment between
## two drones passes through a communication shadow region (map-authored
## AABBs). 0.1 means heavy attenuation inside shadows.
var shadow_attenuation: float = 0.1

var bounds_min: Vector3 = Vector3(-25.0, 0.0, -25.0)
var bounds_max: Vector3 = Vector3(25.0, 15.0, 25.0)


func validate() -> bool:
	if physics_dt <= 0.0 or policy_dt <= 0.0 or physics_substeps < 1:
		push_error("SimConfig: invalid timestep configuration")
		return false
	if absf(physics_dt * float(physics_substeps) - policy_dt) > 1e-6:
		push_error("SimConfig: physics_dt * substeps must equal policy_dt (%f != %f)" \
			% [physics_dt * float(physics_substeps), policy_dt])
		return false
	if max_accel <= 0.0 or max_speed <= 0.0 or max_yaw_rate <= 0.0:
		push_error("SimConfig: limits must be positive")
		return false
	if drone_radius <= 0.0:
		push_error("SimConfig: drone_radius must be positive")
		return false
	return true


func to_dict() -> Dictionary:
	return {
		"physics_dt": physics_dt,
		"policy_dt": policy_dt,
		"physics_substeps": physics_substeps,
		"max_accel": max_accel,
		"max_speed": max_speed,
		"max_yaw_rate": max_yaw_rate,
		"linear_drag": linear_drag,
		"gravity": gravity,
		"hover_compensated": hover_compensated,
		"battery_base_rate": battery_base_rate,
		"battery_accel_rate": battery_accel_rate,
		"drone_radius": drone_radius,
		"bounds_min": bounds_min,
		"bounds_max": bounds_max,
		"radio_range": radio_range,
		"shadow_attenuation": shadow_attenuation,
	}


