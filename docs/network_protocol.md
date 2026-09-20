# Network protocol — Godot RL TCP bridge (protocol version 1)

Phase 2 exposes the simulator to external clients (the Julia trainer) over a
length-framed TCP protocol. Godot is authoritative for everything: episode
state, simulation time, dynamics, scenarios, rewards, termination, truncation,
observations and agent ordering. The client only submits batched actions.

```text
Julia trainer ── length-framed TCP (JSON payloads) ──▶ Godot RL server
                                                         └─ SwarmEnv ─▶ SwarmSimulation
```

## Transport and framing

- TCP, server listens on `127.0.0.1` (loopback) by default, port `9100`.
- Every message is framed as:

```text
┌──────────────────────────┬─────────────────────────────┐
│ payload length: uint32   │ payload: UTF-8 JSON object  │
│ big-endian, 4 bytes      │ (exactly `length` bytes)    │
└──────────────────────────┴─────────────────────────────┘
```

- Maximum payload size: **1 MiB** (`MAX_MESSAGE_BYTES = 1048576`).
- A single TCP read may contain a partial header, a partial payload, or
  several complete frames. Receivers must buffer and reassemble; one read must
  never be assumed to equal one message.
- **Framing violations** — zero length, length > 1 MiB, or invalid UTF-8 —
  are unrecoverable: the server closes the connection (an error response
  cannot be sent because no request context exists). A payload that is valid
  UTF-8 but malformed JSON, or a JSON value that is not an object, is answered
  with a normal error response carrying `request_id: null` and code
  `MALFORMED_MESSAGE`, after which the connection stays open.

## Request envelope

```json
{
  "protocol_version": 1,
  "request_id": 42,
  "command": "STEP",
  "episode_id": 17,
  "payload": {}
}
```

- `protocol_version` (integer, required): must equal the server protocol
  version (1), otherwise `PROTOCOL_VERSION_MISMATCH`.
- `request_id` (integer ≥ 0, required): opaque client token, echoed back in
  the response. The server does **not** enforce uniqueness — duplicate
  request IDs are processed independently (each response echoes the ID it
  carries). Missing/non-integer IDs are rejected with `request_id: null`.
- `command` (string, required): one of `HELLO`, `GET_SPEC`, `RESET`, `STEP`,
  `PING`, `CLOSE`. Anything else → `UNKNOWN_COMMAND`.
- `episode_id` (integer or null): required by `STEP`, ignored by `HELLO` /
  `GET_SPEC` / `PING`, expected `null` for `RESET` / `CLOSE`.
- `payload` (object): command-specific; may be omitted for commands that take
  no arguments.

## Response envelope

```json
{
  "protocol_version": 1,
  "request_id": 42,
  "ok": true,
  "episode_id": 17,
  "result": {},
  "error": null
}
```

Failure:

```json
{
  "protocol_version": 1,
  "request_id": 42,
  "ok": false,
  "episode_id": 17,
  "result": null,
  "error": { "code": "INVALID_ACTION_SHAPE",
             "message": "Expected 4 actions for 4 active agents." }
}
```

Every response preserves the request ID (or `null` when the request had no
valid ID). `episode_id` in the response is the episode the request referred
to (or the server's current episode where relevant).

## Session rules

- **HELLO is mandatory**: it must be the first command on a connection.
  Any other command before HELLO is rejected with `EXPECTED_HELLO`.
- After HELLO, commands may arrive in any order, except `STEP`, which requires
  a live episode (`RESET` first).
- **Episode IDs are server-assigned**, increasing monotonically from 1 for the
  lifetime of the server process, across connections and reconnects. An
  episode ID is only valid while it is the server's current episode: a `STEP`
  naming any other episode (older, newer, or one from a previous connection)
  is rejected with `STALE_EPISODE`.
- **Client disconnect**: the episode counter and server state survive; the
  next connection must HELLO and RESET again (old episode IDs are stale).
- **Max clients**: the server accepts one active client by default
  (`--max-clients=1`); additional connections are closed immediately and the
  event is logged.
- **CLOSE**: the server answers with a normal `ok` response, then closes the
  connection. The process keeps running (it can serve further connections).
- **Stepping a finished episode** (terminated or truncated) is an error:
  `EPISODE_ENDED`. The client must RESET to start a new episode. (Chosen over
  silently returning an unchanged terminal result so client bugs surface.)

## Commands

### HELLO

Request payload:

```json
{ "client_name": "DroneSwarmRL.jl", "client_version": "0.1.0",
  "supported_protocol_versions": [1] }
```

Result:

```json
{ "server_name": "GDST-RL-Simulator", "godot_version": "4.7.1.stable.official",
  "protocol_version": 1,
  "capabilities": ["get_spec", "reset", "step", "batched_agents",
                   "deterministic_seed"] }
```

If no element of `supported_protocol_versions` matches the server version →
`PROTOCOL_VERSION_MISMATCH`.

### GET_SPEC

Result (values derived from `SimConfig` and the scenario, not duplicated
constants):

```json
{
  "action": { "shape_per_agent": [4], "dtype": "float32",
              "minimum": -1.0, "maximum": 1.0,
              "names": ["accel_x", "accel_y", "accel_z", "yaw_rate"] },
  "observation": { "shape_per_agent": [23], "dtype": "float32" },
  "supports_variable_agents": true,
  "minimum_agents": 1, "maximum_agents": 16,
  "scenarios": ["waypoint"],
  "physics_hz": 60, "policy_hz": 20, "substeps": 3
}
```

`maximum_agents` (16) is a server-side policy limit (`RLServer.MAX_AGENTS`),
not a physics constraint.

### RESET

Request payload (`episode_id` in the envelope must be `null`):

```json
{ "seed": 1234, "scenario": "waypoint", "agent_count": 4, "options": {} }
```

- `seed` (integer, required): `0 ≤ seed ≤ 2^63 − 1`, otherwise `INVALID_SEED`.
- `scenario` (string, optional, default `"waypoint"`): unknown names →
  `UNKNOWN_SCENARIO`.
- `agent_count` (integer, optional, default `1`): outside `[1, 16]` →
  `INVALID_AGENT_COUNT`.
- `options` (object, optional): reserved, currently ignored.

Result:

```json
{ "episode_id": 1, "observations": [[...23 floats...], ...],
  "active_mask": [1, 1, 1, 1], "info": { "seed": 1234, "steps": 0 } }
```

`observations[i]` is the 23-float observation of agent `i` in the stable
spawn order. `active_mask[i]` is 1 while agent `i` is active.

### STEP

Request payload (envelope `episode_id` must equal the current episode):

```json
{ "actions": [[0.0, 0.0, 0.0, 0.0], [0.1, 0.0, 0.0, 0.0], ...] }
```

- One action per agent of the **current episode's agent count**, in the stable
  agent order — a single batched request steps the whole swarm. Wrong outer
  length or wrong inner width → `INVALID_ACTION_SHAPE`.
- Each component must be a JSON number and finite. Non-numeric values, and
  numeric literals that overflow to infinity (e.g. `1e999`) or are otherwise
  non-finite → `INVALID_ACTION_VALUE`. (A bare `NaN`/`Infinity` token is not
  valid JSON and is rejected earlier as `MALFORMED_MESSAGE`.) Values are
  clamped to [-1, 1] by the environment, as documented in Phase 1.
- `STEP` before any `RESET` → `NO_ACTIVE_EPISODE`. `STEP` with an episode ID
  that is not current → `STALE_EPISODE`. `STEP` on a terminated/truncated
  episode → `EPISODE_ENDED`.

Result:

```json
{ "episode_id": 1, "observations": [[...], ...], "rewards": [0.5, ...],
  "team_reward": 2.0, "terminated": false, "truncated": false,
  "active_mask": [1, 1, 1, 1],
  "info": { "steps": 1, "successes": 0, "collisions": 0,
            "mean_distance_to_target": 12.34, "seed": 1234,
            "step_time_usec": 85,
            "state_hash": "<sha256 hex>" } }
```

- `observations`, `rewards`, `active_mask` all use the same stable agent
  order (spawn order); `team_reward` is the sum of `rewards`.
- `info.state_hash` is the SHA-256 of `SwarmSimulation.snapshot_packed()`
  after the step — the same value the Phase 1 headless runner prints. It makes
  determinism verifiable over TCP and is unaffected by any visual asset.
- `info.step_time_usec` is the server-measured wall-clock time of the
  environment step itself (integer microseconds, excluding serialization and
  socket I/O). It is instrumentation for benchmarking, not simulation state.

### PING

Result: `{ "pong": true, "server_time_msec": 123456, "episode_id": 1 }`
(`episode_id` is the current episode or `null`).

### CLOSE

Result: `{ "closing": true }`, then the server closes the connection.

## Error codes

| Code | Meaning |
|---|---|
| `MALFORMED_MESSAGE` | Payload not valid JSON, not an object, or structurally unreadable (`request_id: null`). |
| `MISSING_FIELD` | Required envelope/payload field missing or wrong type. |
| `PROTOCOL_VERSION_MISMATCH` | Envelope version ≠ 1, or HELLO shares no version. |
| `UNKNOWN_COMMAND` | Command string not recognized. |
| `EXPECTED_HELLO` | First command on the connection was not HELLO. |
| `INVALID_SEED` | Seed missing, not an integer, or out of range. |
| `UNKNOWN_SCENARIO` | Scenario name not registered. |
| `INVALID_AGENT_COUNT` | Agent count not an integer in [1, 16]. |
| `NO_ACTIVE_EPISODE` | STEP before RESET. |
| `STALE_EPISODE` | STEP episode_id ≠ current episode. |
| `EPISODE_ENDED` | STEP on an already terminated/truncated episode. |
| `INVALID_ACTION_SHAPE` | Wrong action count or action width. |
| `INVALID_ACTION_VALUE` | Non-numeric or non-finite action component. |
| `INTERNAL_ERROR` | Simulator rejected the step (should not happen; message has details). |

## Determinism guarantee

For a fixed Godot build on the pinned platform, `RESET(seed)` followed by an
identical action sequence produces bit-identical logical states, hence
identical `info.state_hash` values — including across client
disconnect/reconnect, and regardless of which visual asset is loaded. JSON
float serialization does not affect this: observations are *outputs*; the
dynamics only consume actions, and any float that round-trips JSON exactly
(such as the `%.17g` shortest-round-trip representation both sides use)
replays identically.

## Future: binary Float32 protocol (Phase 3+)

JSON is the Phase 2 baseline for debuggability. A binary upgrade can replace
only the payload *encoding* without changing environment semantics:

- Keep the 4-byte big-endian length framing and the command set.
- Add `encoding: "f32le"` negotiated in HELLO capabilities. A binary STEP
  payload is `agent_count × 4 × 4` little-endian Float32 action bytes; a
  binary STEP/RESET result is header fields as JSON (terminated flags, info)
  plus a binary section of `agent_count × 23 × 4` observation bytes and
  `agent_count × 4` reward bytes, in the same stable agent order.
- Everything else — envelope fields, error codes, episode semantics,
  clamping, ordering — stays identical, so trainers can switch encodings with
  no behavioural change. The reference measurements in `docs/phase2.md`
  (serialization vs. socket vs. step time) quantify the expected win.
