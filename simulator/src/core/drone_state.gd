class_name DroneState
extends RefCounted

## Typed physical state of one drone.
##
## Replaces the untyped state Dictionary used by the legacy GDST protocols
## for the new RL core. Legacy Lifeline metadata may remain in Dictionaries,
## but physical state and RL observations must only use this type.

## Number of float32 values produced by to_packed_float32().
const FLOAT_COUNT := 17

var agent_id: int = 0
var position: Vector3 = Vector3.ZERO
var velocity: Vector3 = Vector3.ZERO
## Heading around the +Y axis in radians, wrapped to [-PI, PI].
var yaw: float = 0.0
## Yaw rate applied during the last step, in rad/s.
var yaw_rate: float = 0.0
## Remaining battery, normalized to [0, 1].
var battery: float = 1.0
## Inactive drones no longer move and no longer produce observations updates.
var active: bool = true
## True if this drone collided during the last environment step.
var collided: bool = false
## Total number of environment steps in which this drone collided.
var collision_count: int = 0
## Clamped action applied during the last step: (ax, ay, az, yaw_rate).
var previous_action: Vector4 = Vector4.ZERO


func duplicate_state() -> DroneState:
	var s := DroneState.new()
	s.agent_id = agent_id
	s.position = position
	s.velocity = velocity
	s.yaw = yaw
	s.yaw_rate = yaw_rate
	s.battery = battery
	s.active = active
	s.collided = collided
	s.collision_count = collision_count
	s.previous_action = previous_action
	return s


## Returns true when every physical field is finite. Non-finite state is a
## hard error: the swarm core refuses to commit it.
func validate() -> bool:
	return position.is_finite() and velocity.is_finite() \
		and is_finite(yaw) and is_finite(yaw_rate) \
		and is_finite(battery) and is_finite(previous_action.x) \
		and is_finite(previous_action.y) and is_finite(previous_action.z) \
		and is_finite(previous_action.w)


func to_dict() -> Dictionary:
	return {
		"agent_id": agent_id,
		"position": position,
		"velocity": velocity,
		"yaw": yaw,
		"yaw_rate": yaw_rate,
		"battery": battery,
		"active": active,
		"collided": collided,
		"collision_count": collision_count,
		"previous_action": previous_action,
	}


static func from_dict(d: Dictionary) -> DroneState:
	var s := DroneState.new()
	s.agent_id = int(d.get("agent_id", 0))
	s.position = d.get("position", Vector3.ZERO)
	s.velocity = d.get("velocity", Vector3.ZERO)
	s.yaw = float(d.get("yaw", 0.0))
	s.yaw_rate = float(d.get("yaw_rate", 0.0))
	s.battery = float(d.get("battery", 1.0))
	s.active = bool(d.get("active", true))
	s.collided = bool(d.get("collided", false))
	s.collision_count = int(d.get("collision_count", 0))
	s.previous_action = d.get("previous_action", Vector4.ZERO)
	return s


## Fixed layout (FLOAT_COUNT floats):
## [agent_id, px, py, pz, vx, vy, vz, yaw, yaw_rate, battery,
##  active, collided, collision_count, prev_ax, prev_ay, prev_az, prev_yaw_rate]
func to_packed_float32() -> PackedFloat32Array:
	return PackedFloat32Array([
		float(agent_id),
		position.x, position.y, position.z,
		velocity.x, velocity.y, velocity.z,
		yaw, yaw_rate, battery,
		1.0 if active else 0.0,
		1.0 if collided else 0.0,
		float(collision_count),
		previous_action.x, previous_action.y, previous_action.z,
		previous_action.w,
	])


static func from_packed_float32(a: PackedFloat32Array) -> DroneState:
	if a.size() != FLOAT_COUNT:
		push_error("DroneState.from_packed_float32: expected %d floats, got %d" \
			% [FLOAT_COUNT, a.size()])
		return null
	var s := DroneState.new()
	s.agent_id = int(a[0])
	s.position = Vector3(a[1], a[2], a[3])
	s.velocity = Vector3(a[4], a[5], a[6])
	s.yaw = a[7]
	s.yaw_rate = a[8]
	s.battery = a[9]
	s.active = a[10] > 0.5
	s.collided = a[11] > 0.5
	s.collision_count = int(a[12])
	s.previous_action = Vector4(a[13], a[14], a[15], a[16])
	return s
