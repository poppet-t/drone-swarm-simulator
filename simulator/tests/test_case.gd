class_name TestCase
extends RefCounted

## Minimal xUnit-style base for headless tests. Each public test_* method is
## discovered and run by tests/run_tests.gd. Failures are collected, never
## asserted-and-aborted, so one bad test does not hide the others.

var failures: Array[String] = []
var checks := 0


func check(cond: bool, msg: String) -> bool:
	checks += 1
	if not cond:
		failures.append(msg)
		printerr("    FAIL: " + msg)
	return cond


func check_eq(a, b, msg: String) -> bool:
	return check(a == b, "%s (expected %s, got %s)" % [msg, str(b), str(a)])


func check_approx(a: float, b: float, tol: float, msg: String) -> bool:
	return check(absf(a - b) <= tol,
		"%s (expected %f +/- %f, got %f)" % [msg, b, tol, a])


func check_vec3_approx(a: Vector3, b: Vector3, tol: float, msg: String) -> bool:
	return check(a.distance_to(b) <= tol,
		"%s (expected %s +/- %f, got %s)" % [msg, str(b), tol, str(a)])


## Builds a ready-to-step environment for tests.
func make_env(seed: int = 1234, agents: int = 4) -> SwarmEnv:
	var env := SwarmEnv.new()
	env.configure(SimConfig.new())
	if not env.reset(seed, "waypoint", agents):
		push_error("make_env failed: " + env.last_error)
		return null
	return env


## One zero action per agent.
func zero_actions(count: int) -> Array:
	var actions: Array = []
	for _i in range(count):
		actions.append(PackedFloat32Array([0.0, 0.0, 0.0, 0.0]))
	return actions
