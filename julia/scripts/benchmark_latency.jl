# Round-trip latency benchmark for the Julia -> Godot rollout path.
#
# Spawns one headless Godot RL server on a free loopback port, drives a
# waypoint episode with zero actions (deterministic, representative of the
# steady-state request/response cycle) and reports per-phase timings plus
# round-trip median/mean/p95/p99.
#
# Usage:
#   julia --project=julia julia/scripts/benchmark_latency.jl \
#       [--agents=N] [--steps=N] [--seed=S] [--warmup=N] [--json]
#
# `--json` prints machine-readable JSON instead of the human table.

using Sockets
using JSON
using Statistics
using Printf
using DroneSwarmRL

const SIMULATOR_DIR = normpath(joinpath(@__DIR__, "..", "..", "simulator"))
const SERVER_SCRIPT = "res://src/networking/rl_server.gd"

function _parse_args(args)
    opts = Dict{String,String}()
    for arg in args
        m = match(r"--([a-z_]+)(?:=(.+))?", arg)
        if m === nothing
            continue
        elseif m.captures[2] === nothing
            opts[m.captures[1]] = "true"
        else
            opts[m.captures[1]] = String(m.captures[2])
        end
    end
    return opts
end

_free_port() =
    let s = listen(ip"127.0.0.1", 0); p = Int(getsockname(s)[2]); close(s); p; end

function spawn_server(; timeout_s::Real = 30.0)
    port = _free_port()
    logfile = tempname() * "-bench_rl_server.log"
    godot = get(ENV, "GODOT", "godot")
    cmd = `$godot --headless --path $SIMULATOR_DIR -s $SERVER_SCRIPT --
           --host=127.0.0.1 --port=$port --max-clients=1`
    io = open(logfile, "w")
    proc = run(pipeline(cmd; stdout = io, stderr = io); wait = false)
    close(io)  # parent drops its handle; the child keeps its own
    deadline = time() + timeout_s
    while time() < deadline
        process_exited(proc) && break  # likely a port race or startup error
        if isfile(logfile) && occursin(r"^RL_SERVER_READY"m, read(logfile, String))
            return (proc = proc, port = port, logfile = logfile)
        end
        sleep(0.05)
    end
    kill(proc)
    error("godot RL server did not become ready; log: $(read(logfile, String))")
end

function kill_server(srv)
    process_exited(srv.proc) && return
    kill(srv.proc)
    timedwait(() -> process_exited(srv.proc), 5.0; pollint = 0.05)
    process_exited(srv.proc) || kill(srv.proc, Base.SIGKILL)
    try wait(srv.proc) catch end
end

pct(v, q) = v[max(1, min(length(v), ceil(Int, q * length(v))))]

function main()
    opts = _parse_args(ARGS)
    agents = parse(Int, get(opts, "agents", "4"))
    steps = parse(Int, get(opts, "steps", "2000"))
    seed = parse(Int, get(opts, "seed", "20260825"))
    warmup = parse(Int, get(opts, "warmup", "100"))
    as_json = haskey(opts, "json")

    srv = spawn_server()
    try
        env = GodotSwarmEnv("127.0.0.1", srv.port; timeout_s = 30.0)
        connect!(env)
        hello!(env)
        reset!(env; seed = seed, scenario = "waypoint", agent_count = agents)
        zero_a = [zeros(Float32, 4) for _ in 1:agents]

        # Warmup: JIT compilation and first-touch allocations must not skew
        # percentiles.
        for _ in 1:warmup
            step!(env, zero_a)
        end
        reset_perf!(env)

        rt_us = Vector{Float64}(undef, steps)
        for i in 1:steps
            t0 = time_ns()
            result_step = step!(env, zero_a)
            rt_us[i] = (time_ns() - t0) / 1000.0
            # Waypoint truncates at max_steps; keep the benchmark going by
            # starting a fresh episode (reset latency is not sampled).
            if result_step.terminated || result_step.truncated
                reset!(env; seed = seed, scenario = "waypoint", agent_count = agents)
            end
        end

        perf = env.perf
        close(env)
        sorted = sort(rt_us)
        result = Dict(
            "agents" => agents,
            "steps" => steps,
            "roundtrip_us" => Dict(
                "median" => pct(sorted, 0.5),
                "mean" => mean(sorted),
                "p95" => pct(sorted, 0.95),
                "p99" => pct(sorted, 0.99),
                "min" => first(sorted),
                "max" => last(sorted),
            ),
            # Phase means over all measured round trips (us), from PerfStats.
            # receive_incl_server covers everything between the request write
            # returning and the response frame being fully parsed, i.e. server
            # pickup delay + server handling + network + client wakeup.
            "phases_us" => Dict(
                "serialize" => perf.serialize_ns / perf.count / 1000.0,
                "send" => perf.send_ns / perf.count / 1000.0,
                "receive_incl_server" => perf.receive_ns / perf.count / 1000.0,
                "parse_validate" => (perf.roundtrip_ns - perf.serialize_ns -
                    perf.send_ns - perf.receive_ns) / perf.count / 1000.0,
            ),
        )
        if as_json
            println(JSON.json(result))
        else
            println("-"^72)
            @printf("benchmark agents=%d steps=%d seed=%d\n", agents, steps, seed)
            @printf("%-12s %10s %10s %10s %10s\n", "", "median", "mean", "p95", "p99")
            r = result["roundtrip_us"]
            @printf("%-12s %9.1fus %9.1fus %9.1fus %9.1fus\n", "round trip",
                r["median"], r["mean"], r["p95"], r["p99"])
            ph = result["phases_us"]
            @printf("phase means us: serialize=%.1f send=%.1f receive(incl.server)=%.1f parse+validate=%.1f\n",
                ph["serialize"], ph["send"], ph["receive_incl_server"], ph["parse_validate"])
        end
        return result
    finally
        kill_server(srv)
    end
end

main()
