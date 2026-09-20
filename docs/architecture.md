# Simulator architecture

Phase 1 turns the imported GDST codebase into a deterministic,
headless-capable RL simulator. Godot owns simulation time, dynamics,
collisions, scenario logic and (optionally) rendering; Julia owns
learning (Phase 2: over the TCP bridge in `src/networking/`, see
`docs/network_protocol.md`). This document describes the Phase 1
architecture plus the Phase 2 visual layer.

## Layer overview

```text
┌────────────────────────────────────────────────────────────┐
│ Networking (Phase 2) — simulator/src/networking/            │
│  RLServerCore: length-framed TCP JSON server wrapping one   │
│  SwarmEnv. Godot stays authoritative for everything.        │
├────────────────────────────────────────────────────────────┤
│ Rendering (optional) — simulator/src/render, simulator/scenes│
│  SimView / DroneVisual / DroneVisualTextured: READ committed │
│  states, interpolate. Never feeds back into simulation.      │
│  Disabled headlessly. The textured quadcopter (CC-BY, see    │
│  THIRD_PARTY_ASSETS.md) is visual-only: no collision, no     │
│  physics, no influence on state hashes.                      │
├────────────────────────────────────────────────────────────┤
│ Environment boundary — src/core/swarm_env.gd                │
│  SwarmEnv: configure/reset/get_spec/get_observations/       │
│  apply_actions/step/is_terminated/is_truncated/get_rewards/ │
│  get_info. The future Julia API surface.                    │
├────────────────────────────────────────────────────────────┤
│ Scenarios — src/scenarios/                                   │
│  Scenario base + WaypointScenario: spawns, observations,     │
│  rewards, termination. Driven only by the seeded RNG.        │
├────────────────────────────────────────────────────────────┤
│ Simulation core — src/core/                                  │
│  SwarmSimulation (FSYNC compute-then-commit), DroneDynamics  │
│  (fixed-step integrator + analytic collisions), DroneState   │
│  (typed state), SimConfig (all tunables). No Nodes.          │
├────────────────────────────────────────────────────────────┤
│ Legacy GDST — Core/, Impl/, Sim/ (unchanged baseline)        │
│  Original Lifeline protocols + playground, kept runnable.    │
└────────────────────────────────────────────────────────────┘
```

## Synchronous update model (preserved from GDST)

GDST's key property — FSYNC compute-then-commit — is preserved in
`SwarmSimulation.step` (`simulator/src/core/swarm_simulation.gd`):

1. **Compute**: for every drone, `DroneDynamics.integrate(old_state,
   action, ...)` produces a NEW `DroneState` without mutating the old
   one. Every drone therefore observes the same old swarm state.
2. **Validate**: any non-finite candidate aborts the whole step; nothing
   is committed (mirrors the legacy `ExecReturn.fail` behaviour).
3. **Resolve**: drone-drone collisions are resolved between the
   simultaneously computed candidates, symmetrically, in fixed index
   order.
4. **Commit**: `prev_states = states; states = next` in one assignment.
   `step_count` increments once.

`SwarmSimulation.compute_hook` is an instrumentation point used by
`tests/test_sync.gd::test_compute_all_before_commit` to prove no drone
observes a partially committed swarm.

## Determinism

- Fixed timestep: physics 60 Hz, policy 20 Hz, 3 substeps per action
  (`SimConfig`). `physics_dt * substeps == policy_dt` is validated.
- One `RandomNumberGenerator` per episode, created in `SwarmEnv.reset`
  from the reset seed. Scenario setup and stochastic controllers draw
  only from it. No global `randf`/`randomize` anywhere in the new code.
- Integration is explicit semi-implicit Euler in GDScript — the physics
  server is NOT in the dynamics path, so results do not depend on
  physics-engine determinism, flush order or frame rate.
- Collisions are analytic (ground plane, AABB obstacles, AABB bounds,
  sphere-sphere between drones). The rendered obstacle meshes are
  generated from the same AABBs, so visuals and collision cannot drift.
- Consequence: a fixed seed + fixed action sequence replays
  bit-identically on the pinned platform (Godot 4.7.1, Linux x86-64).
  Exact cross-hardware float identity is not guaranteed.

## Simulation vs rendering

- The simulation core (`src/core`, `src/scenarios`) contains no `Node`
  types and can run without a scene tree, which is how the headless
  runner and tests drive it.
- `SimView` (`src/render/sim_view.gd`) steps the env at the policy rate
  inside `_physics_process`; `DroneVisual` nodes interpolate between
  `prev_states` and `states` in `_process`. Interpolation alpha is a
  pure function of wall-clock delta and never writes back.
- No tweens, no animation waits, no GUI callbacks, no `Timer` in the
  step path (GDST's tween-coupled stepping is replaced).
- Training/headless mode never instances the visual scene. Visual mode
  can set `show_extras = false` (labels/HUD off) and raise
  `steps_per_tick` to fast-forward.
- `tests/test_visual.gd` proves rendered positions equal logical
  positions at interpolation alpha 0, 0.5 and 1.

## Textured drone visual (Phase 2, Part A)

- `DroneVisualTextured` (`src/render/drone_visual_textured.gd` +
  `scenes/visuals/drone_visual_textured.tscn`) wraps the imported GLB
  (`assets/models/drone/drone_model.glb`) in a scene of our own — the
  imported source scene is never modified. It implements the same
  contract as the placeholder `DroneVisual`
  (`set_targets`/`interpolate`/`snap`/`set_label_visible`), and
  `SimView.drone_visual_scene` selects which one to instantiate
  (placeholder by default; `scenes/sim_main.tscn` overrides it with the
  textured wrapper).
- Model-space adjustments live in the wrapper, not the asset: uniform
  0.64 scale (model length matches the 0.5 m collision diameter) and
  180° yaw (creator-named front faces Godot's −Z forward). Rationale
  and provenance: `assets/models/drone/README.md`.
- Rotor animation: the GLB exposes four separate rotor meshes
  (`Rotor_FL/FR/BL/BR`); the wrapper reparents them at runtime under
  pivots centred on each rotor and spins them about +Y, adjacent
  rotors counter-rotating. Speed follows commanded effort
  (`previous_action` magnitude); inactive drones spool down. Animation
  auto-disables headless and is visual-only —
  `tests/test_visual_textured.gd` proves the state hash is
  bit-identical with animation forced on.
- Agent differentiation: one shared emissive-marker material with a
  per-instance shader colour derived deterministically from `agent_id`
  (golden-ratio hue walk) — no per-drone materials or textures. A
  selection ring highlights agent 0 in visual mode.
- LOD: not needed — the model is 4,564 tris, so 16 drones ≈ 73k tris
  total, trivial for any GPU (verified with the 16-drone swarm
  screenshot in `docs/images/`). If a high-poly model is ever adopted,
  revisit with a distance switch to the placeholder sphere.
- The visual model never participates in collision, observations,
  rewards, neighbour calculations, bounds, termination or state
  hashes; the analytic collision system and logical `DroneState` are
  untouched.

## Action and observation spaces

See `docs/scenario_api.md`. Summary: action = 4 floats in [-1, 1]
(world-relative acceleration command scaled by `max_accel`, with hover
compensation, plus yaw rate scaled by `max_yaw_rate`); observation = 23
floats per drone (see `WaypointScenario`).

## Directory map

```text
simulator/
├── project.godot            # main scene: scenes/sim_main.tscn
├── Core/ Impl/ Sim/         # legacy GDST (Lifeline baseline, runnable via F1)
├── src/
│   ├── core/                # drone_state, sim_config, drone_dynamics,
│   │                        #   swarm_simulation, swarm_env
│   ├── scenarios/           # scenario base, waypoint_scenario
│   ├── controllers/         # scripted policies (zero/random/waypoint)
│   ├── render/              # sim_view, drone_visual (visual only)
│   └── cli/                 # headless_runner (SceneTree script)
├── scenes/                  # sim_main.tscn, drone_visual.tscn
└── tests/                   # run_tests.gd + test_*.gd
```

## Legacy preservation

`Core/`, `Impl/` and `Sim/` are byte-identical to the imported GDST
(except `project.godot`). The legacy Lifeline playground opens from the
editor or via F1 in the new main scene. `tests/test_legacy.gd` checks
that the scene loads and that `DroneManager.simulate` still runs.
