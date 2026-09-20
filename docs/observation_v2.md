# Observation Specification Version 2

Status: **frozen** for Phase 3 (dataset recording and MAPPO train against this
contract). Version 1 remains available unchanged; every episode selects its
observation contract explicitly.

- Version 1 (legacy, default): 23 floats per agent — see
  `docs/architecture.md` and `WaypointScenario.get_spec`.
- Version 2 (this document): 111 floats per agent, contiguous Float32,
  structured into named blocks published through `GET_SPEC`.

## Design goals

1. One contiguous `Float32` vector per agent for efficient Julia/GPU use.
2. Named-field layout with offsets, lengths and normalization bounds
   advertised by `GET_SPEC` (`observation_layouts["2"]`) — no positional
   guessing, no dictionary-order dependence.
3. Sufficient for MAPPO, SwarmDreamer-style world models and multi-agent
   transformers: own kinematics + mission + local perception + neighbour
   state + communication health.
4. Sim-to-real ready: every field is either directly measurable on a real
   drone or produced by a documented estimator; asynchronous execution is a
   drop-in (message-age/staleness fields exist from day one).
5. Variable agent counts (1–16) with stable neighbour ordering.

## Wire negotiation

- `GET_SPEC` result adds:
  - `"observation_versions": [1, 2]`
  - `"observation_version_default": 1`
  - `"observation_layouts": {"2": {...full named layout...}}`
- `RESET` payload accepts optional integer `"observation_version"`.
  Omitted/`null` → 1 (byte-compatible with all Phase 1/2 clients).
- Unsupported versions fail with error code `OBSERVATION_VERSION_UNSUPPORTED`.
- `RESET` and `STEP` results echo `"observation_version"` alongside
  `"observations"` so consumers never infer the layout.

## Layout (per agent, 111 Float32 values)

### Block A — own_state, offset 0, length 17

| Offset | Field | Normalization / unit | Bounds |
|---|---|---|---|
| 0–2 | position_norm | `(p − center) / half_extent` per axis | [-1, 1] |
| 3–5 | velocity_norm | `v / max_speed` per axis | [-1, 1] |
| 6 | yaw_sin | `sin(yaw)` | [-1, 1] |
| 7 | yaw_cos | `cos(yaw)` | [-1, 1] |
| 8 | yaw_rate_norm | `yaw_rate / max_yaw_rate` (rad/s base) | [-1, 1] |
| 9 | battery | remaining fraction | [0, 1] |
| 10 | collided | collision during last step | {0, 1} |
| 11–14 | previous_action | clamped `[ax, ay, az, yaw_rate]` command | [-1, 1]^4 |
| 15 | active | agent activity flag | {0, 1} |
| 16 | time_fraction | `step_count / scenario.max_episode_steps()` | [0, 1] |

Yaw uses sin/cos to avoid the ±π wrap discontinuity.

### Block B — mission, offset 17, length 7

Scenario-provided goal structure (raw values are normalized by the builder).

| Offset | Field | Meaning | Bounds |
|---|---|---|---|
| 17–19 | goal_vec_norm | `(goal − position) / world_diagonal` | ≈[-1, 1] |
| 20 | goal_dist_norm | `distance(goal, position) / world_diagonal` | [0, ~1] |
| 21 | progress | scenario-defined mission progress | [0, 1] |
| 22 | phase_code_norm | `phase_code / max(max_phase_count, 1)`; semantics published per scenario | [0, 1] |
| 23 | success | local success flag | {0, 1} |

`world_diagonal = |bounds_max − bounds_min|`. Waypoint scenario: goal = shared
target, progress = `1 − dist/start_dist`, phases {0 navigating, 1 landed}.

### Block C — range_sensor, offset 24, length 16

Deterministic logical range finder:

- 16 horizontal rays in the drone-local frame: ray *k* at heading
  `yaw + 2πk/16`.
- Cast analytically against the **logical** world only: obstacle AABBs (slab
  method), ground plane `bounds_min.y`, ceiling `bounds_max.y`, side walls —
  never rendered mesh geometry.
- Value = `hit_distance_m / RANGE_MAX_M` with `RANGE_MAX_M = 20`;
  free space reads 1.0; 0 means "no data" (inactive rows only).

### Block D — neighbours, offset 40, length 66 (6 slots × 11 fields)

Fixed K = 6 slots. Active neighbours sorted by **(distance ascending, then
agent_id ascending)** — a total order that is stable across runs and agent
counts. Slot j holds neighbour j's data; unfilled slots are zeroed with
`valid_mask = 0`.

Per-slot fields (slot base = 40 + 11·j):

| Offset within slot | Field | Meaning | Bounds |
|---|---|---|---|
| 0–2 | rel_position_norm | `(p_j − p_i) / world_diagonal` | ≈[-1, 1] |
| 3–5 | rel_velocity_norm | `v_j / max_speed` | [-1, 1] |
| 6 | rel_yaw_sin | `sin(yaw_j − yaw_i)` | [-1, 1] |
| 7 | rel_yaw_cos | `cos(yaw_j − yaw_i)` | [-1, 1] |
| 8 | link_quality | pairwise link quality to that neighbour | [0, 1] |
| 9 | message_age_norm | age of neighbour data in policy steps / 50 | [0, 1] |
| 10 | valid_mask | slot populated | {0, 1} |

Inactive neighbours never occupy slots; only active agents are candidates.

### Block E — communication_self, offset 106, length 5

| Offset | Field | Meaning | Bounds |
|---|---|---|---|
| 106 | validity | own radio up (1 while active) | {0, 1} |
| 107 | quality_mean | mean link quality over active neighbours (0 if none) | [0, 1] |
| 108 | staleness | normalized age of own view of the swarm (0 = synchronous) | [0, 1] |
| 109 | packet_loss | simulated loss indicator (0 = none simulated yet) | [0, 1] |
| 110 | active_neighbour_fraction | active neighbour count / K | [0, 1] |

The interface assumes nothing about future asynchrony: when execution becomes
asynchronous, `message_age_norm`/`staleness` grow above zero and consumers
must treat neighbour blocks as possibly stale — no layout change required.

## Communication model

Pairwise link quality between drones i, j (deterministic):

```
q(i,j) = max(0, 1 − dist(p_i,p_j)/radio_range)
q(i,j) *= shadow_attenuation   if segment p_i→p_j intersects any comm-shadow AABB
```

Defaults: `radio_range = 30 m`, `shadow_attenuation = 0.1` (SimConfig).
Shadow regions are authored by scenarios/maps as AABBs (returned from
`setup()` under `"comm_shadows"`); they affect observations only, never
dynamics.

## Inactive agents

An inactive (landed/battery-dead) agent returns an all-zero row: own flags 0,
mission zeros, range samples 0 (= no data), all neighbour masks 0,
communication validity 0. Consumers must key behaviour off
`own_state.active` and the masks, not off raw magnitudes.

## Guarantees and tests

- Determinism: identical seed + action sequence ⇒ bit-identical vectors.
- Finiteness: every emitted value is finite for any legal trajectory.
- Conversion: `ObservationV2.build_structured(...)` ↔ `flatten(...)`
  round-trip exactly; both paths tested.
- Legacy safety: version 1 observation code paths and state hashes are
  byte-identical to Phase 2 (guarded by the full regression suite).
