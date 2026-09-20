class_name SimView
extends Node3D

## Visual driver for the swarm simulation.
##
## Rendering is strictly separated from simulation state: the SwarmEnv
## advances at the fixed policy rate inside _physics_process, and this node
## only reads the committed states to position DroneVisual nodes (with
## interpolation between the previous and latest state). Interpolation never
## feeds back into the simulation, and the simulation never waits for
## tweens, animations or rendered frames.

@export var scenario_name := "waypoint"
@export var agent_count := 4
@export var base_seed := 1234
@export var controller_name := "waypoint"
## Environment steps per policy tick; raise to fast-forward visually.
@export var steps_per_tick := 1
## Disables labels/HUD extras (training-style runs).
@export var show_extras := true
## Drone visual scene. Must implement the DroneVisual contract
## (set_targets/interpolate/snap/set_label_visible). The placeholder sphere
## is the default; sim_main.tscn overrides this with the textured wrapper.
@export var drone_visual_scene: PackedScene = preload("res://scenes/drone_visual.tscn")

signal episode_finished(info: Dictionary)

var env: SwarmEnv
var controller: ScriptedController
var episode := 0
var running := true

var _ticks_per_step := 1
var _tick := 0
var _interp_alpha := 0.0
var _restart_delay := 0.0
## DroneVisual-compatible nodes (placeholder or DroneVisualTextured);
## intentionally untyped so either implementation can be used.
var _visuals: Array = []
var _world_root: Node3D
var _target_marker: MeshInstance3D


func _ready() -> void:
	var physics_rate := float(Engine.physics_ticks_per_second)
	_ticks_per_step = maxi(1, roundi(physics_rate * SimConfig.new().policy_dt))
	_world_root = Node3D.new()
	_world_root.name = "WorldVisuals"
	add_child(_world_root)
	_start_episode(base_seed)


func _start_episode(p_seed: int) -> void:
	env = SwarmEnv.new()
	env.configure(SimConfig.new())
	if not env.reset(p_seed, scenario_name, agent_count):
		push_error("SimView: reset failed: " + env.last_error)
		return
	controller = _make_controller(controller_name)
	controller.configure(env.get_spec())
	_build_world_visuals()
	_spawn_visuals()
	_tick = 0
	_interp_alpha = 0.0
	running = true
	_update_hud()


func _physics_process(delta: float) -> void:
	if not running:
		if _restart_delay > 0.0:
			_restart_delay -= delta
			if _restart_delay <= 0.0:
				episode += 1
				_start_episode(base_seed + episode)
		return
	_tick += 1
	if _tick >= _ticks_per_step:
		_tick = 0
		_interp_alpha = 0.0
		for _i in range(steps_per_tick):
			_step_env()
			if not running:
				break


func _process(delta: float) -> void:
	# Interpolation between the previous and latest committed states.
	_interp_alpha = minf(1.0, _interp_alpha + delta / env.config.policy_dt)
	for v in _visuals:
		v.interpolate(_interp_alpha)


func _step_env() -> void:
	var obs: Array = env.get_observations()
	var actions: Array = controller.compute_actions(obs, env.rng)
	if not env.apply_actions(actions):
		push_error("SimView: apply_actions failed: " + env.last_error)
		running = false
		return
	if not env.step():
		push_error("SimView: step failed: " + env.last_error)
		running = false
		return
	for i in range(_visuals.size()):
		_visuals[i].set_targets(env.sim.prev_states[i], env.sim.states[i])
	_update_hud()
	if env.is_terminated() or env.is_truncated():
		running = false
		_restart_delay = 1.0
		emit_signal("episode_finished", env.get_info())


## Test/debug hook: positions the visuals directly from committed states
## with an explicit interpolation alpha (1.0 = latest logical state).
func sync_to_state(alpha: float = 1.0) -> void:
	for i in range(_visuals.size()):
		_visuals[i].set_targets(env.sim.prev_states[i], env.sim.states[i])
		_visuals[i].interpolate(alpha)


func get_visual_positions() -> Array:
	return _visuals.map(func(v): return v.position)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_SPACE:
				running = not running
			KEY_R:
				_start_episode(base_seed + episode)
			KEY_F1:
				# Legacy GDST Lifeline playground (kept as baseline).
				get_tree().change_scene_to_file("res://Sim/3DPlayground.tscn")


func _spawn_visuals() -> void:
	for v in _visuals:
		v.queue_free()
	_visuals.clear()
	for i in range(env.sim.agent_count()):
		var v: Node3D = drone_visual_scene.instantiate()
		add_child(v)
		v.set_targets(env.sim.states[i], env.sim.states[i])
		v.snap()
		v.set_label_visible(show_extras)
		# Selected-agent indicator: visual mode only, never affects the sim.
		if v.has_method("set_selected"):
			v.set_selected(show_extras and i == 0)
		_visuals.append(v)


func _build_world_visuals() -> void:
	for c in _world_root.get_children():
		c.queue_free()
	var config := env.config
	var center := (config.bounds_min + config.bounds_max) * 0.5

	# Ground plane matching the analytic ground (bounds_min.y).
	var ground := MeshInstance3D.new()
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(config.bounds_max.x - config.bounds_min.x,
		config.bounds_max.z - config.bounds_min.z)
	ground.mesh = ground_mesh
	ground.position = Vector3(center.x, config.bounds_min.y, center.z)
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.35, 0.42, 0.28)
	ground.material_override = ground_mat
	_world_root.add_child(ground)

	# Static obstacles: visuals are generated from the exact AABBs the
	# simulation collides against, so they can never drift apart.
	var obs_mat := StandardMaterial3D.new()
	obs_mat.albedo_color = Color(0.55, 0.35, 0.2)
	for box in env.sim.obstacles:
		var m := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = box.size
		m.mesh = bm
		m.material_override = obs_mat
		m.position = box.get_center()
		_world_root.add_child(m)

	# Target marker.
	_target_marker = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.3
	sphere.height = 0.6
	_target_marker.mesh = sphere
	var target_mat := StandardMaterial3D.new()
	target_mat.albedo_color = Color(0.2, 0.8, 0.9)
	target_mat.emission_enabled = true
	target_mat.emission = Color(0.2, 0.8, 0.9)
	_target_marker.material_override = target_mat
	if env.scenario is WaypointScenario:
		_target_marker.position = (env.scenario as WaypointScenario).target
	_world_root.add_child(_target_marker)


func _update_hud() -> void:
	if not show_extras:
		return
	var hud := get_node_or_null("HUD/Label") as Label
	if hud == null:
		return
	var info: Dictionary = env.get_info()
	hud.text = "seed %d | step %d | active %d | successes %d | collisions %d\n" % [
		env.seed, info["steps"], info["active"], info["successes"],
		info["collisions"]] \
		+ "[SPACE] pause  [R] reset  [F1] legacy GDST playground"


func _make_controller(p_name: String) -> ScriptedController:
	match p_name:
		"zero":
			return ZeroController.new()
		"random":
			return RandomController.new()
		_:
			return WaypointController.new()
