# Drone Swarm Simulation

A Godot-based drone swarm simulator with reinforcement-learning
training implemented in Julia. Built on top of
[GDST](references/GDST) (imported into `simulator/`, preserved as the
legacy Lifeline baseline).

## Current phase

**Phase 2 complete**: textured drone visuals (CC-BY quadcopter, purely
visual) and the Julia↔Godot RL bridge — a length-framed TCP server in
Godot plus the `DroneSwarmRL` Julia package. See `docs/phase2.md`.
Phase 1 (deterministic simulation core) is documented in
`docs/phase1.md`.

## Components

- `simulator/` — Godot 4.7.1 project: simulation core, scenarios,
  rendering (incl. the textured drone wrapper in
  `scenes/visuals/`), RL TCP server (`src/networking/`), tests, and the
  legacy GDST playground
- `simulator/assets/` — third-party assets with provenance (see
  `THIRD_PARTY_ASSETS.md`)
- `simulator-clean-prototype/` — early clean-room prototype (archived)
- `julia/` — `DroneSwarmRL` Julia package: protocol client, swarm
  environment, tests, random-policy demo
- `references/` — external reference projects (GDST)
- `docs/` — architecture, protocol and phase documentation
- `scripts/` — helper scripts (smoke tests, RL server launcher)

## Requirements

- Godot 4.7.1 (`godot` on PATH)
- Julia 1.12 (Phase 2 bridge and later; not needed for Phase 1)
- Linux x86-64 (pinned determinism platform)

## Running

```bash
# Visual simulator (editor)
godot --editor --path simulator

# Visual simulator (direct). SPACE pause, R reset, F1 legacy GDST playground
godot --path simulator

# Headless training-style run
godot --headless --path simulator -s res://src/cli/headless_runner.gd -- \
  --training --scenario=waypoint --seed=1234 --agents=4 --steps=1000

# Phase 1 tests + smoke checks
bash scripts/run_headless_smoke_test.sh

# Godot RL TCP server (loopback, single client)
bash scripts/run_godot_rl_server.sh

# Julia client tests (unit + integration, spawns its own servers)
bash scripts/run_julia_integration_tests.sh

# Everything: Phase 1 regression + server startup + Julia integration
bash scripts/run_phase2_smoke_test.sh
```

## Documentation

- `docs/architecture.md` — simulator architecture and determinism model
- `docs/gdst_architecture.md` — review of the original GDST codebase
- `docs/phase1.md` — Phase 1: what was built, fixed config, limitations
- `docs/phase2.md` — Phase 2: textured visuals + Julia bridge, performance
- `docs/scenario_api.md` — environment API, action/observation specs
- `docs/network_protocol.md` — TCP bridge protocol contract (v1)
- `docs/julia_environment.md` — DroneSwarmRL.jl usage
- `docs/testing.md` — how to run and extend the tests
- `THIRD_PARTY_ASSETS.md` — third-party asset attribution (CC-BY)
