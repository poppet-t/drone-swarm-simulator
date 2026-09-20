class_name DroneVisualTextured
extends Node3D

## Visual-only textured quadcopter. Same contract as DroneVisual
## (set_targets/interpolate/snap/set_label_visible) so SimView can swap
## between the placeholder and this wrapper without knowing which one it has.
##
## Wraps the CC-BY 3.0 "Drone" model by NateGazzard
## (res://assets/models/drone/README.md). Rendering only: this node reads
## committed DroneState and never feeds anything back into the simulation.
## No collision shapes are generated from the mesh; the analytic collision
## system and logical DroneState remain the only physics.

## Model-space adjustments (documented in the asset README):
## uniform 0.64 scale -> model length matches the logical collision diameter,
## 180 deg yaw -> creator-named front (Rotor_FL/FR pair) faces Godot -Z.
const MODEL_SCALE := 0.64

const ROTOR_NODE_NAMES := ["Rotor_FL", "Rotor_FR", "Rotor_BL", "Rotor_BR"]
const ROTOR_PIVOT_NAMES := [
	"RotorFrontLeftPivot", "RotorFrontRightPivot",
	"RotorRearLeftPivot", "RotorRearRightPivot",
]
## Spin directions about +Y: adjacent rotors counter-rotate, diagonals match
## (FL/BR one way, FR/BL the other), like a real quadcopter.
const ROTOR_DIRECTIONS := [-1.0, 1.0, 1.0, -1.0]
## Rotor speed range (revolutions/second), mapped from commanded effort.
const MIN_ROTOR_RPS := 6.0
const MAX_ROTOR_RPS := 30.0
## Visual spool-up/down rate (rps per second).
const ROTOR_SPOOL_RATE := 40.0

var _prev_pos := Vector3.ZERO
var _cur_pos := Vector3.ZERO
var _prev_yaw := 0.0
var _cur_yaw := 0.0

## Rotor animation is automatically disabled when running headless; it is a
## pure visual effect and never touches simulation state.
var animation_enabled := true

var _rotor_pivots: Array[Node3D] = []
var _rotor_dirs := PackedFloat32Array()
var _rotor_rps := PackedFloat32Array()
var _rotor_target_rps := 0.0
var _marker_agent_id := -1

@onready var _model_root: Node3D = $ModelRoot
@onready var _marker: MeshInstance3D = $IdMarker
@onready var _selection: MeshInstance3D = $SelectionIndicator
@onready var _label: Label3D = $DebugLabel


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		animation_enabled = false
	_model_root.scale = Vector3.ONE * MODEL_SCALE
	_model_root.rotation.y = PI
	_setup_rotor_pivots()
	_selection.visible = false


## Reparents the model's four rotor meshes under runtime-created pivots
## centred on each rotor, so spinning a pivot spins the rotor about its own
## axis. If a replacement model lacks the separate rotor nodes, this
## degrades gracefully to a static model (documented in the asset README).
func _setup_rotor_pivots() -> void:
	var model := _model_root.get_node_or_null("ImportedDroneModel")
	if model == null and _model_root.get_child_count() > 0:
		model = _model_root.get_child(0)
	if model == null:
		push_warning("DroneVisualTextured: no imported model under ModelRoot")
		return
	for i in range(ROTOR_NODE_NAMES.size()):
		var rotor := model.find_child(ROTOR_NODE_NAMES[i], true, false) as MeshInstance3D
		if rotor == null:
			push_warning("DroneVisualTextured: rotor node '%s' not found; no spin for it" \
				% ROTOR_NODE_NAMES[i])
			continue
		var center: Vector3 = rotor.get_aabb().get_center()
		var pivot := Node3D.new()
		pivot.name = ROTOR_PIVOT_NAMES[i]
		pivot.position = center
		var parent := rotor.get_parent()
		parent.add_child(pivot)
		parent.remove_child(rotor)
		pivot.add_child(rotor)
		rotor.position = -center
		_rotor_pivots.append(pivot)
		_rotor_dirs.append(ROTOR_DIRECTIONS[i])
		_rotor_rps.append(MIN_ROTOR_RPS)


## Deterministic per-agent identification colour (golden-ratio hue walk):
## stable for a given agent_id, distinct across a swarm, no textures needed.
static func agent_color(agent_id: int) -> Color:
	return Color.from_hsv(fposmod(float(agent_id) * 0.61803398875, 1.0), 0.85, 1.0)


## Records the previous and latest committed states as interpolation targets.
func set_targets(prev: DroneState, cur: DroneState) -> void:
	_prev_pos = prev.position
	_cur_pos = cur.position
	_prev_yaw = prev.yaw
	_cur_yaw = cur.yaw
	_label.text = str(cur.agent_id)
	if cur.agent_id != _marker_agent_id:
		_marker_agent_id = cur.agent_id
		_marker.set_instance_shader_parameter("marker_color", agent_color(cur.agent_id))
	# Rotor speed follows commanded effort (same normalized effort measure the
	# dynamics use for battery drain); landed/inactive drones spool down.
	if cur.active:
		var effort: float = Vector3(cur.previous_action.x, cur.previous_action.y,
			cur.previous_action.z).length() / sqrt(3.0)
		_rotor_target_rps = lerpf(MIN_ROTOR_RPS, MAX_ROTOR_RPS, clampf(effort, 0.0, 1.0))
	else:
		_rotor_target_rps = 0.0


## alpha = 0 shows the previous state, alpha = 1 the latest state.
func interpolate(alpha: float) -> void:
	position = _prev_pos.lerp(_cur_pos, alpha)
	rotation.y = lerp_angle(_prev_yaw, _cur_yaw, alpha)


## Jumps straight to the latest state (used by tests and on spawn).
func snap() -> void:
	interpolate(1.0)


func set_label_visible(visible_: bool) -> void:
	_label.visible = visible_


## Highlights this drone as the selected agent (visual mode only).
func set_selected(selected: bool) -> void:
	_selection.visible = selected


## True when the imported model exposed separate rotor meshes.
func has_rotor_animation() -> bool:
	return not _rotor_pivots.is_empty()


func _process(delta: float) -> void:
	if not animation_enabled or _rotor_pivots.is_empty():
		return
	for i in range(_rotor_pivots.size()):
		_rotor_rps[i] = move_toward(_rotor_rps[i], _rotor_target_rps,
			ROTOR_SPOOL_RATE * delta)
		_rotor_pivots[i].rotation.y += _rotor_dirs[i] * _rotor_rps[i] * TAU * delta
