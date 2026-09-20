extends TestCase

## Rendering must display the logical state, never diverge from it.

var tree: SceneTree


func test_visual_matches_logical_state() -> void:
	if tree == null or tree.root == null:
		check(false, "test requires a SceneTree root")
		return
	var view := SimView.new()
	view.show_extras = false
	tree.root.add_child(view)  # triggers _ready -> env reset + visuals
	if view.env == null:
		check(false, "SimView failed to initialize its environment")
		view.queue_free()
		return

	# Drive the environment directly (no frame dependency), then snap the
	# visuals to the latest logical state.
	for _i in range(10):
		view._step_env()
	view.sync_to_state(1.0)
	var ok := true
	for i in range(view.env.sim.agent_count()):
		var logical: Vector3 = view.env.sim.states[i].position
		var visual: Vector3 = (view._visuals[i] as DroneVisual).position
		if visual.distance_to(logical) > 1e-4:
			ok = false
	check(ok, "visual positions match logical positions at alpha = 1")

	# alpha = 0 must show the previous committed state.
	view.sync_to_state(0.0)
	ok = true
	for i in range(view.env.sim.agent_count()):
		var prev: Vector3 = view.env.sim.prev_states[i].position
		var visual: Vector3 = (view._visuals[i] as DroneVisual).position
		if visual.distance_to(prev) > 1e-4:
			ok = false
	check(ok, "visual positions match previous state at alpha = 0")

	# Interpolation midpoint equals the state midpoint.
	view.sync_to_state(0.5)
	ok = true
	for i in range(view.env.sim.agent_count()):
		var mid: Vector3 = view.env.sim.prev_states[i].position.lerp(
			view.env.sim.states[i].position, 0.5)
		var visual: Vector3 = (view._visuals[i] as DroneVisual).position
		if visual.distance_to(mid) > 1e-4:
			ok = false
	check(ok, "interpolation is a pure function of the two committed states")

	tree.root.remove_child(view)
	view.free()
