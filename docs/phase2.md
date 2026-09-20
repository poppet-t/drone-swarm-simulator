# Phase 2 — textured visuals + Julia↔Godot RL bridge

Phase 2 has two independent workstreams:

- **Part A** — replace the placeholder sphere with a properly licensed,
  textured quadcopter model, kept strictly out of the deterministic
  simulation.
- **Part B** — expose the simulator to Julia over a length-framed TCP
  protocol so a trainer can reset and step the whole swarm remotely.

## Part A — textured drone visual

**Asset**: "Drone" by NateGazzard, CC-BY 3.0, via Poly Pizza
(https://poly.pizza/m/DNbUoMtG3H). Full provenance, inspection results and
the (documented) reason the primary Sketchfab choice was not used are in
`simulator/assets/models/drone/README.md`; the required attribution is in
`THIRD_PARTY_ASSETS.md`.

Key properties (verified by `tests/test_visual_textured.gd`):

- glTF 2.0 binary, 4,564 triangles, 6 nodes — including four separate
  rotor meshes, so per-rotor spin works without editing the source.
- One embedded 128×128 base-colour palette texture; **no** normal,
  metallic, roughness or emission maps (the supplied material is used
  as-is; nothing else is claimed).
- Wrapper scene `scenes/visuals/drone_visual_textured.tscn` + script
  `src/render/drone_visual_textured.gd` apply the documented adjustments
  (0.64 scale, 180° yaw, runtime rotor pivots, emissive per-agent id
  marker, selection ring). The imported scene is never modified.
- Visual-only: no collision shapes from the mesh, no RigidBody3D, no
  feedback into simulation. The baseline state hash is unchanged
  (`cc8f3f81…` for the standard smoke run before and after Part A), and
  `test_animation_and_visuals_do_not_change_logical_state` proves the
  hash stays bit-identical with rotor animation forced on.
- Headless mode never requires animation (auto-disabled); 1, 4 and 16
  drones render fine (16 × 4.5k tris ≈ 73k tris — no LOD needed; see
  `docs/architecture.md` for the threshold rationale).
- The placeholder sphere and the legacy GDST Lifeline visual both remain
  available (placeholder is still the `SimView` default; F1 opens the
  legacy playground).

Screenshots for human inspection: `docs/images/textured_drone_closeup.png`,
`docs/images/textured_drone_swarm.png` (regenerate with
`src/cli/capture_screenshots.gd` under `xvfb-run`).

## Part B — Julia bridge

Architecture (Godot authoritative; one batched request per swarm step):

```text
Julia trainer (DroneSwarmRL.jl)
      │  4-byte BE length + UTF-8 JSON
      ▼
Godot RL TCP server (src/networking/rl_server.gd → RLServerCore)
      ▼
SwarmEnv → SwarmSimulation
```

- Protocol contract: `docs/network_protocol.md` (framing, envelope,
  commands HELLO/GET_SPEC/RESET/STEP/PING/CLOSE, error codes, episode
  semantics, determinism guarantee, and the Phase 3 binary-encoding path).
- Godot server files: `simulator/src/networking/` —
  `message_framer.gd` (BE length framing + reassembly),
  `protocol_codec.gd` (JSON envelope validation),
  `protocol_error.gd` (error codes),
  `rl_session.gd` (per-connection command dispatch),
  `rl_server_core.gd` (transport + episode ownership, testable without a
  SceneTree), `rl_server.gd` (SceneTree CLI wrapper).
- Julia package: `julia/` — see `docs/julia_environment.md`.

### Running

```bash
# Godot server (loopback default, single client)
bash scripts/run_godot_rl_server.sh
# → RL_SERVER_READY host=127.0.0.1 port=9100 protocol=1

# Julia rollout demo
julia --project=julia julia/scripts/random_policy_client.jl -- --agents=4 --steps=200

# All Phase 2 checks (Phase 1 regression + server + Julia integration)
bash scripts/run_phase2_smoke_test.sh
```

### Design decisions worth knowing

- **HELLO is mandatory** (first command per connection) so version
  negotiation is explicit.
- **Episode IDs are server-assigned**, monotonically increasing per server
  process; only the current episode accepts STEPs (`STALE_EPISODE`
  otherwise). A disconnect abandons the owned episode.
- **STEP on a finished episode is an error** (`EPISODE_ENDED`) rather than
  an unchanged terminal result, so client bugs surface. Reset to continue.
- **Every STEP result carries `info.state_hash`** (SHA-256 of the packed
  logical state) — the same value the Phase 1 headless runner prints —
  which makes determinism verifiable over TCP, including across reconnects
  and regardless of the loaded visual asset.
- **`info.step_time_usec`** is server-measured env-step wall time, so the
  client can separate simulation cost from transport cost.
- Framing violations (zero length, >1 MiB, invalid UTF-8) close the
  connection; malformed JSON gets a `MALFORMED_MESSAGE` error response with
  `request_id: null` and the connection stays open.

## Performance baseline

Measured on the pinned platform (Godot 4.7.1 headless, Julia 1.12.6,
loopback TCP, JSON payloads) by the informational benchmark in
`julia/test/integration_tests.jl` (~100 STEPs per row, mean per STEP;
serialization/send/receive/round trip measured client-side, server step
from `info.step_time_usec`):

| agents | serialization | socket send | socket receive | server step | round trip |
|---:|---:|---:|---:|---:|---:|
| 1  | 22.4 µs | 68.2 µs | 6666 µs |  87.6 µs | 6757 µs |
| 4  | 26.0 µs | 70.2 µs | 6630 µs | 225.3 µs | 6726 µs |
| 16 | 33.3 µs | 63.0 µs | 6612 µs | 636.4 µs | 6708 µs |

Interpretation:

- The ~6.6 ms round-trip floor is **scheduling overhead, not payload
  cost**: the server polls sockets once per `_process` iteration with a
  1 ms anti-busy-spin delay, and the Julia client waits on its deadline
  with a 1 ms poll interval. Serialization + send stay under 0.1 ms even
  at 16 agents, and receive time is flat in agent count.
- The env step itself scales with the swarm (88 µs → 636 µs for
  1 → 16 agents) and stays two orders of magnitude below the 50 ms
  policy period.
- Conclusion: JSON on loopback is not a training bottleneck at Phase 2
  scale (a 20 Hz policy needs 50 ms; the bridge uses ~7 ms). If larger
  swarms or per-step rendering change that, first drop the server-side
  1 ms poll delay (busy-poll or block on `poll`), then consider the
  binary Float32 encoding sketched in `docs/network_protocol.md` — it
  changes only the payload encoding, not the environment semantics.

## Phase 3 recommendations

- **Training algorithm**: add a PPO (or similar) implementation in Julia on
  top of `GodotSwarmEnv` — keep Lux/CUDA out of `DroneSwarmRL` itself; make
  the algorithm package depend on it.
- **Parallel data collection**: run N Godot server processes on N ports and
  aggregate rollouts; the server is single-client by design, so sharding is
  process-level (also isolates crashes).
- **Binary protocol**: implement the `f32le` encoding from
  `docs/network_protocol.md` if serialization shows up in profiles.
- **Curriculum/scenarios**: new scenarios plug into `Scenario.create`; the
  bridge exposes them through GET_SPEC/RESET with no protocol change.
- **Observations on GPU**: observations already arrive as flat Float32
  matrices in stable agent order — zero-copy upload is straightforward.
