extends SceneTree

## Headless test runner. Usage:
##   godot --headless --path simulator -s res://tests/run_tests.gd
## Prints one PASS/FAIL line per test and a final summary; exits non-zero if
## any test fails. Tests run on the first frame (not in _initialize) so the
## SceneTree root is fully ready for tests that instance scenes.

const TEST_SCRIPTS := [
	"res://tests/test_core.gd",
	"res://tests/test_sync.gd",
	"res://tests/test_determinism.gd",
	"res://tests/test_env_scenario.gd",
	"res://tests/test_visual.gd",
	"res://tests/test_visual_textured.gd",
	"res://tests/test_network.gd",
	"res://tests/test_legacy.gd",
]

var _ran := false


func _process(_delta: float) -> bool:
	if _ran:
		return false
	_ran = true
	_run_all()
	return false


func _run_all() -> void:
	var total_checks := 0
	var total_tests := 0
	var failed_tests := 0

	for path in TEST_SCRIPTS:
		var script: GDScript = load(path)
		if script == null:
			printerr("FAIL %s: could not load test script" % path)
			failed_tests += 1
			continue
		var methods: Array = []
		for m in script.get_script_method_list():
			if String(m["name"]).begins_with("test_"):
				methods.append(m["name"])
		methods.sort()

		for method in methods:
			var tc: TestCase = script.new()
			if "tree" in tc:
				tc.set("tree", self)
			total_tests += 1
			tc.call(method)
			total_checks += tc.checks
			var label := "%s::%s" % [path.get_file(), method]
			if tc.failures.is_empty():
				print("PASS %s (%d checks)" % [label, tc.checks])
			else:
				failed_tests += 1
				print("FAIL %s (%d failures)" % [label, tc.failures.size()])

	print("SUMMARY tests=%d failed=%d checks=%d" % [
		total_tests, failed_tests, total_checks])
	quit(1 if failed_tests > 0 else 0)
