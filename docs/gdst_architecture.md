# GDST architecture review

Source inspected: `references/GDST` (upstream: *GDST — General Drone Swarm
Toolkit*, by Pierre Jaffuer). Godot `4.0` project, main scene
`res://Sim/3DPlayground.tscn`, one autoload (`Tools` =
`Sim/Scripts/Globals/selected_tool.gd`).

This document records what exists, how one simulation step works today, and
what is retained, wrapped, refactored or replaced for the RL simulator.

## 1. Repository layout

```text
GDST/
├── project.godot                 # Godot 4.0, main scene Sim/3DPlayground.tscn
├── Core/                         # scenario-independent logic (pure RefCounted-style classes)
│   ├── Drone.gd                  # logical drone: state Dictionary + compute/commit
│   ├── DroneManager.gd           # FSYNC step: compute all, then commit all
│   ├── Protocol.gd               # base class for swarm protocols
│   └── ExecReturn.gd             # fail/msg/state result object
├── Impl/                         # protocol implementations (the "Lifeline" family)
│   ├── PDefault.gd               # Balabonski et al. flocking/connexion protocol
│   ├── PReturn.gd                # return-to-base protocol (bi-partition variant)
│   ├── PReturnO2.gd              # return-to-base (local-maximum removal variant)
│   ├── PReturnO2_final.gd        # final version of PReturnO2
│   └── ProtocolFactory.gd        # name -> protocol instance
└── Sim/                          # Godot presentation layer
    ├── 3DPlayground.tscn         # main GUI application scene (CanvasLayer GUI + SubViewport)
    ├── SimulationView.tscn       # SubViewport world: floor, camera, light, DroneManager3D
    ├── Drone3D.tscn              # RigidBody3D drone visual (mesh, label, detection Area3D)
    ├── GUI/                      # SimPlayer (recording/playback), Gizmo, FailWindow
    ├── Scripts/
    │   ├── 3DPlayground.gd       # GUI controller (protocol choice, test load/save, trees)
    │   ├── MainView.gd           # SubViewport controller (mouse tools, camera)
    │   ├── CamControls.gd        # WASD/QE camera
    │   ├── Lines3D.gd            # immediate-mode line drawing for connexion graph
    │   ├── MeshCreator.gd        # procedural circle/cylinder vision-range meshes
    │   ├── Drone/Drone3D.gd      # visual drone wrapper, tween-based movement
    │   ├── DroneManager/DroneManager3D.gd  # the actual simulation driver (see §3)
    │   ├── Globals/selected_tool.gd        # `Tools` autoload: current mouse tool enum
    │   └── GUI/                  # SimPlayer.gd, SimPlayerFrame.gd, FailWindow.gd, Gizmo.gd
    ├── Shaders/ Drone3D.gdshader # per-instance color shader
    └── Textures/                 # floor textures
```

## 2. Core classes

- **`Drone`** (`Core/Drone.gd`) — holds `state: Dictionary`, `_next_state`,
  and a `_get_neighbours` Callable injected by the visual layer.
  `compute_next_state(protocol, base_pos)` refreshes neighbours, calls
  `protocol.look(state, neighbours)` then `protocol.compute(state, obs,
  base_pos)`, and on success stores the result in `_next_state`.
  `update_state()` commits `_next_state` to `state`.
- **`DroneManager`** (`Core/DroneManager.gd`) — `simulate(drones, protocol,
  base_pos)`: first loop computes every drone's next state (aborting on the
  first `ExecReturn.fail`), second loop commits. **This is the FSYNC
  compute-then-commit behaviour that Phase 1 must preserve.**
- **`Protocol`** (`Core/Protocol.gd`) — defines `look`, `compute`,
  `get_default_state`, `get_max_dist_from_base`, `get_max_move_dist`,
  `migrate_state`, plus presentation hooks `get_vision_shape` /
  `get_vision_meshes`. State is an untyped `Dictionary` with keys `id`,
  `active`, `position`, `light`, protocol extras (`border`, `returning`) and
  the sim-internal `KILL` flag.
- **`ExecReturn`** — `(fail: bool, msg: String, state: Dictionary)`.
- **Protocols in `Impl/`** — discrete grid-step protocols: drones move exactly
  `D = 0.3` m per step along computed directions; neighbourhood = who is
  within `7*D`; collision = another drone within `D`. `PReturn*` add the
  "Lifeline" behaviour: a search team (drone id 0, moved by the user) explores
  while relay drones maintain a connexion graph back to the base, then return
  and are captured (`KILL = true`).

## 3. How one simulation step works today

The driver is `DroneManager3D._physics_process` (`Sim/Scripts/DroneManager/DroneManager3D.gd`):

1. `_perform_actions()` handles queued GUI requests: reset, load frame,
   protocol switch, kill inactive, manual deploy, **auto-deploy of a new drone
   at the base whenever no active drone is within `3*D` of it** (Area3D
   overlap check on `$Base/Detection`), and removal of `KILL`ed drones.
2. `_simulation_step()`:
   - Collects `Drone` objects from the `Drone3D` children.
   - Calls `DroneManager.simulate` (compute-all-then-commit-all).
   - Moves the search team drone (id 0) directly toward `_search_target_pos`
     by mutating its state dictionary (max `D` per step).
   - Emits `update_drone_state` per drone for the GUI tree.
   - **Creates one Tween per drone (`Drone3D._move`, physics-process mode,
     `movement_time` seconds) and `await`s every tween's `finished` signal** —
     the next simulation step cannot start until the animations complete.
     Simulation speed is therefore coupled to tween duration.
   - Diffs previous vs new states and emits `new_frame` (recorded by the
     `SimPlayer` GUI) or `no_op`.

Neighbour detection: each `Drone3D` owns an `Area3D` (`$Detection`) whose
shape comes from `protocol.get_vision_shape()`; `get_neighbours()` returns
`get_overlapping_bodies()` filtered by id — i.e. physics-server Area3D
overlap. The base detection area uses the same mechanism.

## 4. Lifeline-specific vs presentation-specific code

- **Lifeline/protocol-specific**: everything in `Impl/` (PDefault, PReturn,
  PReturnO2, PReturnO2_final), the `border`/`returning`/`light`/`KILL` state
  keys, the auto-deploy-from-base rule, the search-team target logic
  (`_search_drone`, `_search_target_pos`), and the base `Detection` Area3D.
- **Presentation-specific**: `3DPlayground.gd` (GUI), `MainView.gd`,
  `CamControls.gd`, `SimPlayer*` (frame recording/playback), `FailWindow`,
  `Gizmo`, `Lines3D`, `MeshCreator` vision meshes, the `Tools` autoload,
  the Drone3D shader/label/color logic, and the tween movement in
  `Drone3D._move` + the `await t.finished` in `DroneManager3D`.
- **GUI dependencies**: the whole `Sim/GUI` tree, protocol MenuButton, scene
  tree of drone states, test load/save (JSON scenario files with `Expression`
  parsing of positions in units of `D`).
- **Timer dependencies**: none (no `Timer` nodes); time coupling is via
  Tweens only.
- **Random-number usage**: none. GDST is fully deterministic already (no
  `randf`/`randi`/`randomize` anywhere).

## 5. Search results requested by Task 1

| Topic | Finding |
|---|---|
| Tween usage | `Drone3D._move` / `update` create one tween per drone per step; awaited in `DroneManager3D._simulation_step` |
| `await` usage | tween `finished` (DroneManager3D:233); `await ready` guards (Drone3D, DroneManager3D, SimPlayerFrame) |
| Physics body types | `Drone3D`: `RigidBody3D` (used kinematically — tweens set `position` directly); `Area3D` for vision and base detection; static floor |
| Simulation-step entry points | `DroneManager3D._physics_process` → `_simulation_step`; GUI play/step buttons; `SimPlayer` playback |
| Drone creation/deletion | `_deploy_new_drone` (auto from base, or right-click), `queue_free` on `KILL`/reset/kill-inactive |
| Neighbour detection | `Area3D.get_overlapping_bodies()` with protocol-specific vision shape |
| Protocol selection | `ProtocolFactory` + GUI MenuButton; `migrate_state` converts dictionaries between protocols |
| Dictionary state keys | `id`, `active`, `position`, `light`, `border`, `returning`, `KILL` |
| Main scene / autoloads | `Sim/3DPlayground.tscn`; autoload `Tools` |

## 6. Retain / wrap / refactor / replace

- **Retain as legacy baseline (unchanged)**: `Core/`, `Impl/`, and the whole
  `Sim/` playground as the *Lifeline legacy scenario*. It remains runnable
  from the editor and acts as the reference for the FSYNC semantics.
- **Carry the semantics into the new RL core** (`src/`):
  - compute-all-then-commit-all stepping (`DroneManager.simulate` pattern),
    re-implemented over typed `DroneState` objects with an explicit
    old-state snapshot;
  - `ExecReturn`-style validation (fail fast, never commit partial state);
  - scenario-specific logic behind a protocol/scenario interface, like
    `Protocol` already does.
- **Refactor**: drone state moves from untyped `Dictionary` to a typed
  `DroneState` (RefCounted) with explicit serialization; dictionary use is
  kept only for legacy Lifeline metadata.
- **Replace**: tween-coupled stepping (rendering reads sim state, never the
  other way), Area3D neighbour detection (replaced by analytic queries over
  the committed state so headless mode needs no physics flush), GUI-driven
  simulation control (replaced by the environment API + CLI runner).

## 7. Godot 4.0 → 4.7.1 migration notes

Recorded during import (Task 2). Expected/observed items:

- GDST's `project.godot` targets feature `4.0`; opening in 4.7.1 re-imports
  all assets. No script-API breakage was found in `Core/`/`Impl/`/`Sim/`
  scripts — they use only stable 4.x APIs (`Tween`, `Area3D`, `RigidBody3D`,
  typed arrays, lambdas).
- `rendering/renderer/rendering_method="mobile"` and
  `3d/run_on_separate_thread=true` from GDST are kept for the legacy scenes.
- `common/max_physics_steps_per_frame=1` from GDST is **removed** for the RL
  simulator: headless fast-forward runs many environment steps per rendered
  frame and must not be capped.
- The new simulator keeps the engine default physics tick (60 Hz) as the
  simulation clock and does not rely on `RigidBody3D` integration for
  determinism; drone motion is integrated explicitly (see
  `docs/architecture.md`).
