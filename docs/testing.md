# Testing

All Godot-side tests are built-in GDScript run by Godot itself — no
third-party framework. The Julia package has its own `Test`-stdlib suite
(unit + integration). One command runs everything:

```bash
# Phase 1 regression + RL server startup + Julia unit & integration tests
bash scripts/run_phase2_smoke_test.sh

# just the Phase 1 smoke (startup + unit tests + headless run + determinism)
bash scripts/run_headless_smoke_test.sh

# just the Godot unit tests
godot --headless --path simulator -s res://tests/run_tests.gd

# just the Julia tests (spawns and reaps its own Godot servers)
bash scripts/run_julia_integration_tests.sh
```

## Godot suite

`run_tests.gd` discovers every `test_*` method in the scripts listed in
its `TEST_SCRIPTS`, prints `PASS`/`FAIL` per test and a `SUMMARY` line,
and exits non-zero on any failure. `TestCase` (`tests/test_case.gd`)
provides `check`/`check_eq`/`check_approx`/`check_vec3_approx`;
failures are collected so one bad test never hides the rest.

Current suite: **68 tests, 408 checks.**

| File | Covers |
|---|---|
| `test_core.gd` | project startup/config, reset determinism, fixed timestep (analytic integration match), hover compensation, action clamping, NaN/Inf/shape/count rejection, max-speed enforcement |
| `test_sync.gd` | compute-all-before-commit (instrumented hook proves no drone sees a partially committed swarm), simultaneous movement, stable agent order with deactivation, ground/obstacle/bounds/drone-drone collision reporting |
| `test_determinism.gd` | bit-identical replay of a fixed action sequence from a fixed seed, seeded-controller determinism, divergence across seeds |
| `test_env_scenario.gd` | spec/observation shapes, active mask, waypoint-controller success, zero-action truncation, rewards/info keys, 100-step headless smoke |
| `test_visual.gd` | rendered positions match logical positions at interpolation alpha 0, 0.5 and 1 (placeholder visual) |
| `test_visual_textured.gd` | textured wrapper loads with 4 rotor pivots; imported model resource intact (6 meshes, 128×128 palette texture on every surface, 4,564 tris); 16 wrappers instantiate with unique agent colours; visual transforms track committed logical transforms; rotor animation forced on leaves the state hash bit-identical; animation auto-disabled headless; placeholder remains available |
| `test_network.gd` | BE framing (encode, fragmented header/payload, multi-frame feeds, zero/oversized), codec (malformed JSON, non-object, missing/duplicate request id, bad version), session gate (EXPECTED_HELLO), RESET/STEP validation (seed, agent count, scenario, action shape/values incl. `1e999`), result shapes, GET_SPEC, determinism through the JSON pipeline, real loopback socket test with 1-byte fragments |
| `test_legacy.gd` | legacy GDST Lifeline scene loads, legacy FSYNC `DroneManager.simulate` runs, all legacy protocols build |

## Julia suite

`julia/test/runtests.jl` (125 assertions):

- `protocol_tests.jl` — framing round-trip and big-endianness, empty /
  fragmented / multi-frame / oversized payloads, envelope validation,
  and a loopback **mock server** exercising the real client: handshake,
  canned server errors (`GodotServerError` with codes), garbage replies
  (`GodotConnectionError`, env closed), client-side validation with zero
  server interaction, idempotent close. No Godot required.
- `integration_tests.jl` — spawns a real headless Godot server on a
  free port (port-0 bind), waits for `RL_SERVER_READY`, then: HELLO and
  GET_SPEC shapes, RESET(4) 4×23 observations, a ≥1000-step rollout
  across episodes, increasing episode ids + `STALE_EPISODE` rejection,
  client-side width rejection, malformed raw bytes, TCP determinism
  (same seed + actions ⇒ identical `state_hash`, across a reconnect),
  and the informational 1/4/16-agent benchmark. Servers are always
  killed in `finally` blocks; skips with a warning when godot or the
  server script is missing.

Notes:

- The NaN/Inf rejection tests intentionally trigger `push_error` logs
  from `SwarmEnv.apply_actions` — rejection must be loud, never silent.
  ERROR lines in the output are expected and do not fail the run.
- The determinism tests require bit-identical state on the pinned
  platform (Godot 4.7.1, Linux x86-64); tolerance 0. See
  `docs/phase1.md` for the determinism statement. The TCP determinism
  tests prove the visual asset and the network path do not affect it.
- `scripts/run_headless_smoke_test.sh` additionally runs the real CLI
  runner and compares SHA-256 state hashes of two identical seeded runs.
- `scripts/run_phase2_smoke_test.sh` ends by checking that no Godot or
  Julia processes are left behind.
