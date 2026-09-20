# Phase 1 — deterministic simulation core

## Goal

Convert GDST into a deterministic, headless-capable drone-swarm
simulation core that a Julia RL trainer can later drive through a
batched environment API.

## What was built

| Task | Result |
|---|---|
| 1. Inspect GDST | `docs/gdst_architecture.md` |
| 2. Import | GDST copied to `simulator/` (no `.git`), imports and runs clean on Godot 4.7.1; clean prototype preserved in `simulator-clean-prototype/` |
| 3. FSYNC preserved | `SwarmSimulation.step`: compute all → validate all → commit all; instrumented test |
| 4. Typed state | `DroneState` (RefCounted) with dict + packed-Float32 serialization and finite validation |
| 5. Rendering split | `SimView`/`DroneVisual` read-only visuals with interpolation; no tweens/GUI/timers in the step path |
| 6. Dynamics | `[ax, ay, az, yaw_rate] ∈ [-1,1]^4`, hover-compensated semi-implicit Euler, speed/yaw clamps, drag, battery |
| 7. World | ground plane, 2 AABB obstacle pillars, world bounds, collision flags + counts |
| 8. Env API | `SwarmEnv` + `Scenario` base + `WaypointScenario` |
| 9. Observations/controllers | 23-float obs; zero / seeded-random / waypoint proportional controllers |
| 10. Seeding | one reset seed drives spawns, target, obstacles, controllers; bit-identical replay test |
| 11. Headless CLI | `src/cli/headless_runner.gd` + `scripts/run_headless_smoke_test.sh` |
| 12. Tests | 29 tests / 80 checks, all passing |
| 13. Docs | this file, `architecture.md`, `scenario_api.md`, `testing.md`, README |

## Fixed configuration (SimConfig defaults)

| Parameter | Value |
|---|---|
| physics timestep | 1/60 s |
| policy timestep | 1/20 s |
| substeps per action | 3 |
| max acceleration | 6.0 m/s² |
| max speed | 6.0 m/s |
| max yaw rate | π rad/s |
| linear drag | 0.8 1/s |
| gravity | 9.8 m/s², hover-compensated (never reaches the integrator) |
| battery | base drain 1/600 s⁻¹ + effort term 1/300 s⁻¹ |
| drone radius | 0.25 m |
| world bounds | x,z ∈ [-25, 25] m, y ∈ [0, 15] m |

## GDST import notes (initial run record)

First headless run after import (`godot --headless --path simulator
--quit-after 5`, Godot 4.7.1): exit 0, no parser errors; two
pre-existing exit-cleanup warnings from GDST (`ObjectDB instances were
leaked at exit`, one leaked `GodotShape3D` RID) caused by GDST creating
collision shapes at runtime without freeing. Non-fatal; the new main
scene does not trigger them. `godot --editor` requires a display, so
the editor-side import was verified with `--headless --import`.

Godot 4.0 → 4.7.1 migration: no script changes were required for the
legacy code. `project.godot` was adjusted: project renamed, main scene
set to `scenes/sim_main.tscn`, GDST's `max_physics_steps_per_frame=1`
and `physics_jitter_fix=0.0` removed (they would throttle/fast-break
headless fast-forward and add jitter noise).

## Determinism statement

Pinned platform: Godot 4.7.1.stable.official, Linux x86-64. On this
platform a fixed seed + fixed action sequence replays **bit-identically**
(test tolerance 0, verified by double-run SHA-256 of the packed final
state). Cross-hardware float identity is not claimed.

## Known limitations (Phase 1)

- Actions are acceleration commands, not rotor commands (by design).
- Drone-drone collision is detected once per environment step between
  the simultaneously computed candidates; fast drones could tunnel
  through each other within a step (documented, acceptable at 6 m/s ×
  50 ms = 0.3 m per step vs 0.5 m contact distance).
- Neighbour representation is a single nearest neighbour (Phase 4 will
  add communication-graph observations).
- Waypoint scenario uses one shared target for all drones.
- Collision model is analytic primitives (plane/AABB/sphere), not
  arbitrary meshes.
- The legacy GDST GUI remains Godot-4.0-era code; it runs, but it is
  not part of the RL path.

## Phase 2 plan (preview)

TCP bridge (JSON first, length-framed, request/episode IDs): HELLO,
GET_SPEC, RESET, STEP, CLOSE. One request per swarm step, batched
observations/actions, timeout and invalid-input handling, clean
reconnect. Julia package in `julia/` exposing `reset!`/`step!`/`close`.
Integration test: headless Godot worker + 1000 steps.
