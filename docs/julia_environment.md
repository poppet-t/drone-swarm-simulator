# Julia environment — DroneSwarmRL.jl

`julia/` is a standalone Julia package implementing the client side of the
Phase 2 bridge. It connects to the Godot RL TCP server
(`docs/network_protocol.md`), resets and steps the whole swarm with one
batched request per step, and never touches simulation state directly —
Godot remains authoritative for dynamics, rewards, observations,
termination and agent ordering.

## Layout

```text
julia/
├── Project.toml              # DroneSwarmRL 0.1.0; deps: JSON + stdlibs
├── Manifest.toml             # gitignored — see "Reproducible setup"
├── src/
│   ├── DroneSwarmRL.jl       # module + exports
│   ├── Protocol.jl           # framing, envelopes, exceptions
│   └── GodotSwarmEnv.jl      # env type, API, PerfStats
├── test/
│   ├── runtests.jl           # everything; integration skips w/o server
│   ├── protocol_tests.jl     # framing/envelope/mock-server unit tests
│   └── integration_tests.jl  # real Julia↔Godot tests
└── scripts/
    └── random_policy_client.jl
```

## Reproducible setup

`Manifest.toml` is intentionally gitignored (repo policy). Instantiate with:

```bash
julia --project=julia -e 'using Pkg; Pkg.instantiate()'
```

This resolves the single non-stdlib dependency, JSON.jl (developed and
tested against JSON 1.6.1 on Julia 1.12.6). Stdlibs used: Sockets, Test,
Random, Printf. To reproduce the exact tested dependency set, pin JSON to
1.6.1 (`Pkg.pin("JSON")` after `Pkg.add(name="JSON", version="1.6.1")`).

## Quick start

```bash
# 1. Start the Godot server (loopback, one client)
bash scripts/run_godot_rl_server.sh          # or: godot --headless --path simulator \
                                             #  -s res://src/networking/rl_server.gd -- \
                                             #  --host=127.0.0.1 --port=9100 --max-clients=1

# 2. Run a seeded random-policy rollout from Julia
julia --project=julia julia/scripts/random_policy_client.jl -- \
  --port=9100 --seed=1234 --agents=4 --steps=200
```

## API

```julia
using DroneSwarmRL

env = GodotSwarmEnv("127.0.0.1", 9100; timeout_s = 10.0)
connect!(env)                      # TCP connect (deadline enforced)
hello!(env)                        # mandatory handshake; negotiates protocol v1
spec = get_spec!(env)              # cached in env.spec

ep = reset!(env; seed = 1234, scenario = "waypoint", agent_count = 4)
# (episode_id, observations, active_mask, info)
# observations :: Vector{Vector{Float32}} — one 23-float row per agent,
# stable spawn order (obs layout: docs/scenario_api.md)

result = step!(env, actions)
# actions: 4×4 matrix or vector of 4 vectors of 4 floats in [-1, 1]
#   (accel_x, accel_y, accel_z, yaw_rate — one row per agent, same order)
# result :: (observations, rewards, team_reward, terminated, truncated,
#            active_mask, info); info["state_hash"] is the SHA-256 of the
#            logical state, info["step_time_usec"] the server step time

ping!(env)                         # diagnostics
close(env)                         # CLOSE handshake + socket close; idempotent
```

Errors:

- `ArgumentError` — client-side validation (wrong action count/width,
  non-finite values, step before reset). Thrown **before** anything is sent.
- `GodotServerError` — the server rejected a valid request; carries `code`
  and `msg` from the error envelope (e.g. `STALE_EPISODE`, `EPISODE_ENDED`,
  `INVALID_ACTION_SHAPE`). The connection stays usable; `env.episode_id` is
  left untouched.
- `GodotConnectionError` — socket failure, timeout, or a desynchronised
  response stream. The env is marked closed; recovery requires an explicit
  `connect!` (then `hello!` + `reset!` — old episode IDs are stale).
- `ProtocolFramingError` — framing-level violation (fatal to the connection).

The env never reconnects silently mid-episode. Episode IDs are
server-assigned, monotonically increasing for the server's lifetime; a STEP
naming anything but the current episode is rejected with `STALE_EPISODE`,
and stepping a terminated/truncated episode fails with `EPISODE_ENDED`
(reset to continue).

## Performance instrumentation

Every env accumulates `PerfStats`: serialization (JSON encode + framing),
socket send, socket receive, server-side env step (from
`info["step_time_usec"]`), and total round trip. Use `reset_perf!(env)` and
`print_perf(env; label = "...")`; the random-policy client prints the table
at the end of a run. Baseline numbers live in `docs/phase2.md`.

## Tests

```bash
bash scripts/run_julia_integration_tests.sh
# or directly:
julia --project=julia julia/test/runtests.jl
```

- `protocol_tests.jl` — framing (big-endianness, fragmentation, multi-frame
  buffers, zero/oversize), envelope validation, and a loopback mock server
  exercising the real client (handshake, canned errors, garbage replies,
  idempotent close). No Godot needed.
- `integration_tests.jl` — spawns a real headless Godot server on a free
  port (found via a port-0 bind), waits for the `RL_SERVER_READY` line, and
  runs: hello/spec shapes, reset shapes, a ≥1000-step rollout across
  episodes, multiple resets, stale-episode rejection, malformed-request
  handling, client-side shape rejection, TCP determinism (identical seed +
  action sequence ⇒ identical `state_hash`, across a reconnect), and an
  informational 1/4/16-agent benchmark. Servers are always killed in
  `finally` blocks — no orphaned processes. The suite skips with a warning
  when `godot` or `simulator/src/networking/rl_server.gd` is missing.
