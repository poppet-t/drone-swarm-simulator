extends TestCase

## The original GDST Lifeline implementation is preserved as a legacy
## baseline: its scene must still load and its FSYNC core must still run.


func test_legacy_playground_scene_loads() -> void:
	var packed := load("res://Sim/3DPlayground.tscn") as PackedScene
	check(packed != null, "legacy 3DPlayground.tscn loads")
	if packed == null:
		return
	var instance := packed.instantiate()
	check(instance != null, "legacy playground instantiates")
	if instance != null:
		instance.free()  # never added to the tree: free immediately


func test_legacy_fsync_still_works() -> void:
	# The original compute-then-commit core, exercised directly.
	var protocol: Protocol = PDefault.new()
	var states: Array[Drone] = []
	for i in range(3):
		var s: Dictionary = protocol.get_default_state()
		s["id"] = i
		s["position"] = Vector3(i * 0.3, 0.3, 0)
		var get_neighbours := func(): return states.filter(
			func(d): return d.state["id"] != i)
		states.append(Drone.new(s, get_neighbours))
	var manager := DroneManager.new()
	var ok := true
	for _i in range(10):
		var exec: ExecReturn = manager.simulate(states, protocol, Vector3.ZERO)
		if exec.fail:
			ok = false
			break
	check(ok, "legacy DroneManager.simulate runs 10 steps without failure")


func test_legacy_protocols_all_build() -> void:
	var names := ProtocolFactory.get_names()
	check(names.size() >= 4, "all legacy protocols are registered")
	var ok := true
	for i in range(names.size()):
		if ProtocolFactory.build(i) == null:
			ok = false
	check(ok, "every legacy protocol builds")
