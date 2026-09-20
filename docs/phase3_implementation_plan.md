# Phase 3 Implementation Plan

Status: living document, updated as workstreams land.
Branch: `phase3-research-benchmark` (from `refactor-gdst-for-rl` @ `11d0c98`).

## Verified starting point (2026-08-25)

- `godot --version` → 4.7.1.stable.official.a13da4feb
- `julia --version` → julia version 1.12.6
- `bash scripts/run_phase2_smoke_test.sh` → **PHASE 2 SMOKE TEST OK**
  - Phase 1 suite incl. textured asset tests: pass; determinism hashes equal.
  - RL server startup line + HELLO/PING/CLOSE over TCP: ok.
  - Julia suite: **125/125 checks pass** (framing 28, envelope 18, mock server 47,
    hello/get_spec 11, reset shape 5, 1000-step rollout 2, episode-id staleness 3,
    action-width rejection 3, determinism hash 2, perf benchmark 3, raw-bytes 3).
  - No leftover Godot/Julia processes (`pgrep` clean).
- Uncommitted working-tree churn found before branching (Godot VRAM texture
  re-import metadata + regenerated docs PNG) was inspected, backed up to
  `/tmp/p3_backup`, and restored; baseline matches `11d0c98`.
- Latency profile from the smoke-test benchmark (mean over ~101 round trips):

| agents | serialize | send | receive | server step | round trip |
|---|---|---|---|---|---|
| 1 | 24.6 us | 73.2 us | 6675.7 us | 98.4 us | 6773.4 us |
| 4 | 29.2 us | 76.3 us | 6763.2 us | 257.6 us | 6868.7 us |
| 16 | 34.9 us | 62.2 us | 6548.1 us | 704.8 us | 6645.3 us |

## Workstream plan

### W1 — Rollout communication overhead (Step 2)

Root causes identified by inspection:

1. Server (`rl_server.gd::_process`) sleeps a fixed `OS.delay_msec(1)` every
   iteration even while traffic is flowing → average ~0.5 ms added pickup
   latency per direction, more with timer overshoot.
2. Client (`GodotSwarmEnv._recv_frame`) spawns a fresh `@async` reader +
   `Channel` per round trip and then polls completion with
   `timedwait(...; pollint=0.001)` → up to ~1 ms wakeup quantization plus
   per-call task/channel allocation.
3. Client TCPSocket has no explicit `TCP_NODELAY`; request frames share the
   kernel's Nagle/delayed-ACK heuristics with server responses.

Fixes (protocol semantics untouched: length framing, request IDs, episode IDs,
error codes, fragmentation handling, batched steps all preserved):

- Server: `RLServerCore.poll()` reports whether it did work (bytes consumed,
  frames dispatched, connections accepted). CLI wrapper replaces the fixed
  1 ms sleep with adaptive backoff: hot path re-polls immediately, idle path
  sleeps 400 us via `OS.delay_usec` (no full-core busy loop while idle).
- Client: one persistent reader task per connection feeding an inbox guarded
  by a `ReentrantLock`/`Condition`; `_recv_frame` waits on the condition
  (instant wakeup) with a `Timer` watchdog enforcing the timeout. Sets
  `nodelay!` on the socket at connect.

Verification: new `julia/scripts/benchmark_latency.jl` reports
median/mean/p95/p99 round-trip for 1/4/16 agents before and after; full Julia
suite (protocol regressions) stays green; determinism hashes unchanged.

### W2 — Observation contract v2 (Step 3)

- New `observation_version = 2`, coexisting with v1 (never removed).
- Flat contiguous Float32 vector, structured named fields published through
  GET_SPEC (`observation_versions`, per-version layout with offsets/lengths/
  normalization bounds).
- Fields: own state (pos/vel/yaw sin-cos/yaw rate/battery/collision/prev
  action/active/time fraction), mission block, deterministic 16-ray range
  sensor against logical AABBs, K=6 stable-ordered neighbours (rel pos/vel/
  yaw, link quality, message age, mask), comm self-state.
- Docs: `docs/observation_v2.md`. Tests: shape/offsets, structured↔flat
  conversion, finiteness, determinism, v1 hash invariance.

### W3 — Procedural tactical maps (Step 4)

- `simulator/src/maps/topology/` graph model (rooms/corridors/courtyards/
  vertical connectors/spawn/objective/relay regions + edge classes),
  `simulator/src/maps/generators/` four families (A courtyard-perimeter,
  B corridor-room network, C vertical atrium, D asymmetric mixed),
  `simulator/src/maps/metrics/` the 14 documented metrics,
  AABB-only logical geometry (works headless, drives dynamics directly).
- Deterministic regeneration from (family, seed, params); serialized map ID =
  family/version/seed digest. Split manifests under `configs/maps/`
  (train/validation/test_known_generator/test_unseen_topology).
- Debug visualizer scene, disableable headless.

### W4 — Research scenarios + baselines (Steps 5-6)

- FormationScenario (line/wedge/circle), CoverageScenario (logical grid),
  RelayScenario (base↔explorer connectivity, generalizes Lifeline concept
  without touching legacy code). Common Scenario API, seeded reset,
  decomposed reward terms, per-scenario metrics, obs-v2 support, scripted
  baseline controllers (proportional waypoint, leader-follower,
  potential-field, greedy frontier, relay-chain, seeded random, zero).

### W5 — Parallel rollout workers (Step 7)

- `julia/src/workers/{WorkerProcess,WorkerPool,PortAllocator,RolloutCollector}.jl`:
  spawn N headless Godot processes, free-port allocation, readiness-line wait,
  stdout/stderr capture, startup-failure detection, concurrent reset/step,
  restart between episodes only (data loss reported), guaranteed child cleanup
  on exit/exception/test failure, deterministic seed assignment.
- CLI: `julia/scripts/benchmark_rollouts.jl` reporting env steps/s, agent
  steps/s, latency quantiles, utilization, startup time at 1/4/8 workers.

### W6 — Versioned trajectory dataset (Step 8)

- Chunked shard format (JLD2-based sharded chunks, gzip-compressed records),
  manifest.json per dataset + per-shard checksums, atomic finalization,
  incomplete-shard detection, schema validation, train/val/test manifests.
- `docs/dataset_schema.md`; committed micro-fixture for tests only; datasets
  gitignored. CLI: `julia/scripts/collect_dataset.jl`.

### W7 — MAPPO baseline (Steps 9-10)

- Separate project `julia/research/` (Lux, Optimisers, MLUtils, Zygote via
  Lux; CPU-functional, CUDA optional extension). Shared Gaussian actor
  (tanh-bounded), centralized critic on global state, GAE(λ), clipped PPO,
  value loss, entropy bonus, grad clipping, advantage normalization, masks,
  terminal/truncation bootstrap, observation normalization, TOML config,
  seeds, checkpoints/resume. Mathematical unit tests (hand-computed GAE,
  ratio/clipping/entropy/tanh log-prob correction, masked losses, bootstrap,
  checkpoint round-trip).
- Train waypoint (3 seeds) through real Godot workers; evaluate held-out
  seeds/maps/unseen family vs random/zero/scripted; formation reported
  honestly either way.

### W8 — Benchmark manifests + real-world hooks (Steps 11-12)

- Immutable `configs/benchmarks/*.toml` (waypoint/formation/coverage/relay/
  sim_to_real_contract v1).
- Interface-only `julia/research/src/deployment/`: SwarmBackend/GodotBackend/
  RealBackend/SafetyFilter + TelemetryFrame/CommandFrame/TimeSyncStatus;
  simulated fault-injection tests; "digital-twin-ready" wording only.

### W9 — Smoke script, docs, commits (final)

- `scripts/run_phase3_smoke_test.sh`: phase 1+2 suites, map/scenario/obs-v2
  tests, worker pool, dataset, MAPPO unit tests, one real optimization update
  vs live workers, short held-out eval, process-cleanup verification.
- Docs listed in the milestone; focused commits per workstream.

## W1 results (2026-08-25)

Root cause was NOT per-component overhead but Godot's headless frame pacing:
headless forces low-processor usage mode whose default frame sleep is exactly
6900 us, so every server loop iteration cost ~6.89 ms regardless of load
(verified with an empty SceneTree script: 6890 us/frame even with no sleep;
runtime `OS.low_processor_usage_mode = false` is ignored by the headless main
loop, but `OS.low_processor_usage_mode_sleep_usec` is honoured).

Changes:
- `simulator/src/networking/rl_server.gd`: set
  `low_processor_usage_mode_sleep_usec = 300` once at startup; removed the
  redundant `OS.delay_msec(1)`.
- `julia/src/GodotSwarmEnv.jl`: replaced per-roundtrip `@async` task +
  `Channel` + `timedwait(pollint=0.001)` with one persistent reader task
  feeding an inbox guarded by a `Threads.Condition` (instant wakeup; the
  watchdog Timer enforces the timeout), plus explicit `TCP_NODELAY`.
- New `julia/scripts/benchmark_latency.jl` (median/mean/p95/p99 over a seeded
  zero-action episode) and a silent-server timeout regression testset.

Round-trip STEP latency, 2000 samples after ~100 warmup steps
(same machine, same seed):

| agents | median before | median after | p95 before | p95 after | speedup |
|---|---|---|---|---|---|
| 1 | 6906 us | 299 us | 8038 us | 334 us | 23x |
| 4 | 6904 us | 599 us | 8176 us | 666 us | 11.5x |
| 16 | 6901 us | 1146 us | 9159 us | 1254 us | 6x |

Limiting component after the fix: JSON serialization/parsing of the batched
observation payload on both ends (grows linearly with agent count); server
simulation step remains <210 us mean at 16 agents. Protocol semantics are
untouched: framing, request IDs, episode IDs, error codes, fragmentation,
batched steps, and all determinism hashes are unchanged (full Phase 2 suite +
Godot 68 tests / 408 checks pass).
