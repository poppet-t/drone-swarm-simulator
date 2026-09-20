extends TestCase

## Tests for the textured drone visual wrapper (Part A of Phase 2).
## Proves the wrapper loads, the imported model has intact textures, the
## visual layer follows committed logical state, and that touching the
## visual layer (including rotor animation) never changes deterministic
## simulation state.

var tree: SceneTree

const WRAPPER_SCENE := "res://scenes/visuals/drone_visual_textured.tscn"
const MODEL_PATH := "res://assets/models/drone/drone_model.glb"
const PLACEHOLDER_SCENE := "res://scenes/drone_visual.tscn"
const PIVOT_NAMES := [
	"RotorFrontLeftPivot", "RotorFrontRightPivot",
	"RotorRearLeftPivot", "RotorRearRightPivot",
]


func _make_wrapper() -> DroneVisualTextured:
	var scene: PackedScene = load(WRAPPER_SCENE)
	var v: DroneVisualTextured = scene.instantiate()
	tree.root.add_child(v)  # triggers _ready: rotor pivots, headless check
	return v


func test_wrapper_scene_loads() -> void:
	var scene: PackedScene = load(WRAPPER_SCENE)
	check(scene != null, "wrapper scene loads")
	if scene == null:
		return
	var v: Node3D = scene.instantiate()
	check(v is DroneVisualTextured, "wrapper root is a DroneVisualTextured")
	check(v.get_node_or_null("ModelRoot/ImportedDroneModel") != null,
		"imported model is instanced under ModelRoot")
	tree.root.add_child(v)
	check(v.has_rotor_animation(), "four rotor pivots created from model")
	for n in PIVOT_NAMES:
		check(v.find_child(n, true, false) != null, "pivot %s exists" % n)
	tree.root.remove_child(v)
	v.free()


func test_model_resource_and_textures() -> void:
	check(ResourceLoader.exists(MODEL_PATH), "drone_model.glb exists as a resource")
	var model_scene: PackedScene = load(MODEL_PATH)
	check(model_scene != null, "drone_model.glb loads as a PackedScene")
	if model_scene == null:
		return
	var model: Node3D = model_scene.instantiate()
	var meshes: Array = []
	_collect_meshes(model, meshes)
	check(meshes.size() == 6, "model has 6 mesh instances (got %d)" % meshes.size())
	var all_textured := true
	var total_tris := 0
	for m in meshes:
		var mi := m as MeshInstance3D
		var mat := mi.get_active_material(0)
		if mat == null or mat.albedo_texture == null:
			all_textured = false
			continue
		var img: Image = mat.albedo_texture.get_image()
		if img == null or img.get_size() != Vector2i(128, 128):
			all_textured = false
		total_tris += mi.mesh.get_faces().size() / 3
	check(all_textured, "every mesh surface has the 128x128 palette base-colour texture")
	check(total_tris == 4564, "triangle count matches inspected asset (4564, got %d)" % total_tris)
	model.free()


func test_swarm_instantiation_16() -> void:
	var visuals: Array = []
	for i in range(16):
		visuals.append(_make_wrapper())
	check(visuals.size() == 16, "16 textured wrappers instantiated")
	var colors := {}
	var unique := true
	for i in range(16):
		var c := DroneVisualTextured.agent_color(i)
		if colors.has(c):
			unique = false
		colors[c] = true
	check(unique, "agent identification colours unique across 16 drones")
	for v in visuals:
		tree.root.remove_child(v)
		v.free()


func test_visual_transforms_follow_logical_state() -> void:
	var env := SwarmEnv.new()
	env.configure(SimConfig.new())
	check(env.reset(99, "waypoint", 4), "env reset")
	var v := _make_wrapper()
	# Drive the env directly and snap the wrapper like SimView does.
	for i in range(4):
		env.apply_actions(_hover_actions(env, 0.1 * float(i)))
	env.step()
	v.set_targets(env.sim.prev_states[1], env.sim.states[1])
	v.interpolate(1.0)
	check(v.position.distance_to(env.sim.states[1].position) < 1e-4,
		"visual position equals latest logical position")
	check(absf(wrapf(v.rotation.y - env.sim.states[1].yaw, -PI, PI)) < 1e-4,
		"visual yaw equals latest logical yaw")
	v.interpolate(0.0)
	check(v.position.distance_to(env.sim.prev_states[1].position) < 1e-4,
		"visual position equals previous logical position at alpha 0")
	tree.root.remove_child(v)
	v.free()


func test_animation_and_visuals_do_not_change_logical_state() -> void:
	# Reference run: no visuals at all.
	var hash_plain := _run_with_visuals(4, 60, false)
	# Visual run: textured wrapper updated and rotor animation forced ON
	# every step (even though tests run headless, where it defaults off).
	var hash_visual := _run_with_visuals(4, 60, true)
	check(hash_plain == hash_visual,
		"state hash identical with animated textured visuals attached")
	check(hash_plain.length() == 64, "sha256 hash produced")


func test_headless_animation_disabled_but_optional() -> void:
	var v := _make_wrapper()
	if DisplayServer.get_name() == "headless":
		check(not v.animation_enabled, "animation auto-disabled headless")
	# Headless tests must not require animation: snap/interpolate work with
	# animation off, and manual stepping of _process is a no-op.
	var pivot := v.find_child(PIVOT_NAMES[0], true, false) as Node3D
	check(pivot != null, "pivot found")
	if pivot == null:
		tree.root.remove_child(v)
		v.free()
		return
	var before: float = pivot.rotation.y
	v._process(0.1)
	check(is_equal_approx(pivot.rotation.y, before),
		"disabled animation does not rotate rotors")
	# When explicitly enabled (visual mode), rotors do spin — purely visually.
	v.animation_enabled = true
	v._process(0.1)
	check(not is_equal_approx(pivot.rotation.y, before),
		"enabled animation rotates rotors (visual only)")
	tree.root.remove_child(v)
	v.free()


func test_placeholder_visual_remains_available() -> void:
	var scene: PackedScene = load(PLACEHOLDER_SCENE)
	check(scene != null, "original placeholder drone_visual.tscn still loads")
	if scene == null:
		return
	var v: Node3D = scene.instantiate()
	check(v is DroneVisual, "placeholder is still a DroneVisual")
	v.free()


func _hover_actions(env: SwarmEnv, x: float) -> Array:
	var actions: Array = []
	for i in range(env.sim.agent_count()):
		actions.append(PackedFloat32Array([x, 0.0, 0.0, 0.0]))
	return actions


## Runs a seeded episode, optionally attaching an animated textured wrapper
## to drone 0 and feeding it committed states each step. Returns the sha256
## of the final logical state (same function the headless runner uses).
func _run_with_visuals(agents: int, steps: int, with_visual: bool) -> String:
	var env := SwarmEnv.new()
	env.configure(SimConfig.new())
	env.reset(42, "waypoint", agents)
	var v: DroneVisualTextured = null
	if with_visual:
		v = _make_wrapper()
		v.animation_enabled = true  # force on despite headless
	for s in range(steps):
		var actions: Array = []
		for i in range(env.sim.agent_count()):
			# Deterministic pseudo-random actions from the step index.
			var a := PackedFloat32Array([
				sin(float(s) * 0.7 + float(i)), cos(float(s) * 0.3),
				sin(float(s) * 0.11), cos(float(s) * 0.5 + float(i))])
			actions.append(a)
		env.apply_actions(actions)
		env.step()
		if v != null:
			v.set_targets(env.sim.prev_states[0], env.sim.states[0])
			v.interpolate(1.0)
			v._process(0.05)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(env.sim.snapshot_packed().to_byte_array())
	var hash := ctx.finish().hex_encode()
	if v != null:
		tree.root.remove_child(v)
		v.free()
	return hash


func _collect_meshes(n: Node, out: Array) -> void:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_collect_meshes(c, out)
