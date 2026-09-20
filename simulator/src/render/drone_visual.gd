class_name DroneVisual
extends Node3D

## Visual representation of one drone. Rendering only: it reads committed
## simulation states and interpolates between them. Nothing here ever feeds
## back into the simulation — the sim core does not know this node exists.

var _prev_pos := Vector3.ZERO
var _cur_pos := Vector3.ZERO
var _prev_yaw := 0.0
var _cur_yaw := 0.0

@onready var _mesh: MeshInstance3D = $Mesh
@onready var _label: Label3D = $Label3D


## Records the previous and latest committed states as interpolation targets.
func set_targets(prev: DroneState, cur: DroneState) -> void:
	_prev_pos = prev.position
	_cur_pos = cur.position
	_prev_yaw = prev.yaw
	_cur_yaw = cur.yaw
	_label.text = str(cur.agent_id)
	# GDST-style per-instance color: gray when inactive, red on the step a
	# collision happened, dark otherwise.
	var color := Color(0.05, 0.05, 0.05)
	if not cur.active:
		color = Color.LIGHT_GRAY
	elif cur.collided:
		color = Color.RED
	_mesh.set_instance_shader_parameter("color", color)


## alpha = 0 shows the previous state, alpha = 1 the latest state.
func interpolate(alpha: float) -> void:
	position = _prev_pos.lerp(_cur_pos, alpha)
	rotation.y = lerp_angle(_prev_yaw, _cur_yaw, alpha)


## Jumps straight to the latest state (used by tests and on spawn).
func snap() -> void:
	interpolate(1.0)


func set_label_visible(visible_: bool) -> void:
	_label.visible = visible_
