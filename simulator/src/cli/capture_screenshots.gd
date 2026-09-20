extends SceneTree

## Screenshot capture for human inspection of the textured drone visuals.
## Requires a display (real X or xvfb-run); does NOT work with --headless.
##
## Usage:
##   xvfb-run -a godot --path simulator -s res://src/cli/capture_screenshots.gd -- \
##       --mode=closeup --out=docs/images/textured_drone_closeup.png
##   xvfb-run -a godot --path simulator -s res://src/cli/capture_screenshots.gd -- \
##       --mode=swarm --agents=16 --out=docs/images/textured_drone_swarm.png

const TEXTURED_VISUAL := preload("res://scenes/visuals/drone_visual_textured.tscn")

var _mode := "closeup"
var _out := "docs/images/textured_drone_closeup.png"
var _agents := 16
var _frames := 0
var _settle_frames := 30
var _capture_step := 40  # swarm mode: capture at this env step, not a frame count
var _built := false
var _main: Node3D


func _initialize() -> void:
	var opts := _parse_args(OS.get_cmdline_user_args())
	_mode = opts.get("mode", "closeup")
	_out = opts.get("out", "docs/images/textured_drone_closeup.png")
	_agents = int(opts.get("agents", "16"))
	root.size = Vector2i(1280, 720)


func _process(_delta: float) -> bool:
	if not _built:
		# Build on the first frame: the SceneTree root is not ready for
		# instanced scenes during _initialize (same constraint as run_tests).
		_built = true
		match _mode:
			"closeup":
				_build_closeup()
			"swarm":
				_build_swarm()
			_:
				printerr("capture_screenshots: unknown mode '%s'" % _mode)
				quit(1)
				return true
		return false
	_frames += 1
	if _mode == "swarm":
		# llvmpipe rendering runs several physics ticks per rendered frame,
		# so frame counting is meaningless here: capture at a fixed env step
		# of the first episode (drones airborne, mid-flight).
		var view := _main as SimView
		if view == null or view.env == null or view.env.sim.step_count < _capture_step:
			return false
	elif _frames < _settle_frames:
		return false
	var img := root.get_texture().get_image()
	var save_path := _out
	if not save_path.begins_with("/") and not save_path.contains("://"):
		# Resolve repo-relative paths: the Godot project dir is simulator/,
		# the repo root is its parent.
		save_path = ProjectSettings.globalize_path("res://").path_join("..") \
			.path_join(_out).simplify_path()
	var err := img.save_png(save_path)
	if err != OK:
		printerr("capture_screenshots: save_png failed: %s" % error_string(err))
		quit(1)
		return true
	print("SCREENSHOT_SAVED %s (%dx%d)" % [_out, img.get_width(), img.get_height()])
	return true


func _build_closeup() -> void:
	var world := Node3D.new()
	root.add_child(world)
	_add_light_and_env(world)
	# One textured drone at the origin, rotors spinning: force animation on
	# (it auto-disables only headless, but be explicit for robustness).
	var drone: DroneVisualTextured = TEXTURED_VISUAL.instantiate()
	world.add_child(drone)
	drone.position = Vector3(0.0, 0.5, 0.0)
	drone.rotation.y = -PI / 6.0
	drone.animation_enabled = true
	# Selection ring + id marker visible for the showcase shot.
	drone.set_selected(true)
	drone.set_label_visible(false)
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.position = Vector3(0.75, 0.72, 0.9)
	cam.look_at(Vector3(0.0, 0.48, 0.0), Vector3.UP)
	cam.current = true


func _build_swarm() -> void:
	# Instance the real main scene so the swarm is shown with its proper
	# camera, sunlight, environment and HUD (and the textured visual that
	# sim_main overrides into SimView).
	_main = load("res://scenes/sim_main.tscn").instantiate()
	_main.scenario_name = "waypoint"
	_main.agent_count = _agents
	_main.base_seed = 1234
	_main.controller_name = "waypoint"
	root.add_child(_main)
	# Pull the camera back a little so the whole spawn volume is in frame.
	var cam := _main.get_node_or_null("Camera3D") as Camera3D
	if cam != null:
		cam.position = Vector3(0.0, 18.0, 26.0)
		cam.look_at(Vector3(0.0, 2.0, 0.0), Vector3.UP)


func _add_light_and_env(world: Node3D) -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	sun.shadow_enabled = true
	world.add_child(sun)
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.18, 0.2, 0.26)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.85, 0.88, 0.92)
	env.ambient_light_energy = 0.9
	env_node.environment = env
	world.add_child(env_node)
	# Neutral ground so the drone silhouette reads clearly.
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(10.0, 10.0)
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.4, 0.42, 0.45)
	ground.material_override = mat
	world.add_child(ground)


func _parse_args(args: PackedStringArray) -> Dictionary:
	var opts := {}
	for arg in args:
		if arg.begins_with("--"):
			var kv := arg.trim_prefix("--").split("=", true, 1)
			if kv.size() == 2:
				opts[kv[0]] = kv[1]
			else:
				opts[kv[0]] = true
	return opts
