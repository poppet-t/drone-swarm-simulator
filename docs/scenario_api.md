# Scenario / environment API

The `SwarmEnv` class (`simulator/src/core/swarm_env.gd`) is the boundary
Julia will talk to in Phase 2. Everything is batched per swarm step.

## Lifecycle

```gdscript
var env := SwarmEnv.new()
env.configure(SimConfig.new())            # validate + store config
env.reset(seed, "waypoint", agent_count)  # seeded episode init
var spec := env.get_spec()
var obs := env.get_observations()
while not (env.is_terminated() or env.is_truncated()):
    if env.apply_actions(actions):        # validate + clamp, reject bad input
        env.step()                        # one fixed policy step (50 ms)
    obs = env.get_observations()
var rewards := env.get_rewards()
var info := env.get_info()
```

Rules:

- `apply_actions(actions)` expects exactly one `PackedFloat32Array` of
  size 4 per agent (stable index = `agent_id`). Wrong count, wrong size,
  NaN or ±Inf → rejected (`false`, `last_error` set, logged); the
  previous actions are kept. Valid actions are clamped to [-1, 1].
- `step()` with no applied actions uses zero actions (hover).
- Julia (and scripted controllers) can only submit actions. Drone
  positions are never settable through the API.
- Agent ordering is stable: slot `i` always holds `agent_id == i`, even
  after deactivation (variable ACTIVE count, fixed array size).

## get_spec() (waypoint)

```json
{
  "scenario": "waypoint", "agent_count": 4,
  "obs_size": 23, "action_size": 4,
  "action_low": -1.0, "action_high": 1.0,
  "policy_dt": 0.05, "max_steps": 500,
  "obs_layout": { "position": 0, "velocity": 3, "yaw_sin_cos": 6,
    "rel_target": 8, "dist_target": 11, "collided": 12, "battery": 13,
    "previous_action": 14, "active": 18,
    "nearest_neighbour": 19, "nearest_neighbour_dist": 22 }
}
```

## Action space (per agent, 4 floats, [-1, 1])

| Index | Meaning | Scaling |
|---|---|---|
| 0 | accel command x (world) | × max_accel (6 m/s²) |
| 1 | accel command y (world, up) | × max_accel; 0 = hold altitude (hover compensation) |
| 2 | accel command z (world) | × max_accel |
| 3 | yaw rate command | × max_yaw_rate (π rad/s) |

## Observation space (per agent, 23 floats)

| Index | Content | Normalization |
|---|---|---|
| 0–2 | position | centered, ÷ half-extent per axis → ~[-1, 1] |
| 3–5 | velocity | ÷ max_speed |
| 6–7 | yaw (sin, cos) | unit circle, no wrap discontinuity |
| 8–10 | target − position | ÷ world diagonal |
| 11 | distance to target | ÷ world diagonal |
| 12 | collided this step | 0/1 |
| 13 | battery | [0, 1] |
| 14–17 | previous action | [-1, 1] as applied (clamped) |
| 18 | active mask | 0/1 |
| 19–21 | nearest active neighbour − position | ÷ world diagonal; zeros if none |
| 22 | distance to nearest neighbour | ÷ world diagonal; 1.0 if none |

## Rewards (waypoint)

Per agent per step, only while active:

`r = (prev_dist − dist) − 0.01 (time) − 1.0 × collided + 10.0 × success`

Reaching `dist ≤ 0.75 m` = success: the drone lands (`active = false`),
giving a variable active-agent count. Episode **terminates** when no
active drones remain; **truncates** at 500 steps.

## Adding a scenario

Subclass `Scenario` (`src/scenarios/scenario.gd`), implement `setup`
(seeded spawns + obstacles), `build_observations`, `compute_rewards`,
`is_terminated`, `is_truncated`, `get_spec`, `get_info`, and register it
in `Scenario.create`. The legacy GDST Lifeline protocols stay under
`Impl/` and are not part of this API.

## Headless CLI

```bash
godot --headless --path simulator -s res://src/cli/headless_runner.gd -- \
  --training --scenario=waypoint --seed=1234 --agents=4 --steps=1000 \
  --controller=waypoint   # or random, zero
```

Prints `KEY VALUE` lines: SCENARIO, SEED, AGENTS, STEPS_RUN, TERMINATED,
TRUNCATED, TOTAL_REWARD, SUCCESSES, COLLISIONS, MEAN_DIST, WALL_MS,
STATE_HASH (SHA-256 of the packed final logical state). Exit code 0 on
success, 1 on any failure.
