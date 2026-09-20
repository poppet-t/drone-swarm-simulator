# End-to-end tests against the real Godot RL server.
#
# These require a `godot` binary (set the GODOT env var to override the name)
# and the server script at simulator/src/networking/rl_server.gd. If godot is
# not found, the whole file skips gracefully.

using Test
using Sockets
using JSON
using Random
using DroneSwarmRL

"""Pick a free loopback port by binding port 0 and releasing it."""
function _free_port()::Int
    port, server = listenany(ip"127.0.0.1", 0)
    close(server)
    return Int(port)
end

"""
    spawn_godot_server(godot_path; attempts=3, ready_timeout_s=30.0)

Launch `godot --headless` with the RL server script on a free port, stdout and
stderr redirected to a temp log file. Polls the log for a line starting with
`RL_SERVER_READY`. Returns a NamedTuple `(proc, port, logfile)`, or `nothing`
if the server never became ready. The caller MUST kill `proc` (see
[`with_godot_server`](@ref)).
"""
function spawn_godot_server(godot_path::AbstractString; attempts::Int = 3,
                            ready_timeout_s::Real = 30.0)
    simulator_dir = normpath(joinpath(@__DIR__, "..", "..", "simulator"))
    for attempt in 1:attempts
        port = _free_port()
        logfile = tempname() * "-rl_server.log"
        cmd = `$godot_path --headless --path $simulator_dir
               -s res://src/networking/rl_server.gd --
               --host=127.0.0.1 --port=$port --max-clients=1`
        io = open(logfile, "w")
        proc = run(pipeline(cmd; stdout = io, stderr = io); wait = false)
        close(io)  # parent drops its handle; the child keeps its own
        deadline = time() + ready_timeout_s
        while time() < deadline
            process_exited(proc) && break  # likely a port race or startup error
            if isfile(logfile) && occursin(r"^RL_SERVER_READY"m, read(logfile, String))
                return (proc = proc, port = port, logfile = logfile)
            end
            sleep(0.1)
        end
        _kill_process(proc)
        @warn "godot server attempt $attempt/$attempts did not become ready" logfile
    end
    return nothing
end

function _kill_process(proc)
    process_exited(proc) && return
    kill(proc)
    if timedwait(() -> process_exited(proc), 2.0; pollint = 0.05) == :timed_out
        kill(proc, Base.SIGKILL)
    end
    try wait(proc) catch end
    return nothing
end

function _print_server_log(logfile)
    if isfile(logfile)
        println("\n----- Godot server log ($logfile) -----")
        println(read(logfile, String))
        println("----- end Godot server log -----")
    end
end

"""
    with_godot_server(f, godot_path)

Spawn the server, call `f(port)`, print the server log on any failure, and
ALWAYS kill the process in a `finally` — no orphaned godot processes.
"""
function with_godot_server(f, godot_path::AbstractString)
    srv = spawn_godot_server(godot_path)
    srv === nothing && error("Godot RL server did not become ready")
    try
        f(srv.port)
    catch
        _print_server_log(srv.logfile)
        rethrow()
    finally
        _kill_process(srv.proc)
    end
end

function run_integration_tests(godot_path::String)
    with_godot_server(godot_path) do port
        env = GodotSwarmEnv("127.0.0.1", port; timeout_s = 15.0)
        connect!(env)

        @testset "hello + get_spec" begin
            hello = hello!(env)
            @test haskey(hello, "server_name")
            @test hello["protocol_version"] == 1

            spec = get_spec!(env)
            @test env.spec === spec
            @test spec["action"]["shape_per_agent"] == [4]
            @test spec["observation"]["shape_per_agent"] == [23]
            @test spec["minimum_agents"] == 1
            @test spec["maximum_agents"] == 16
            @test spec["physics_hz"] == 60
            @test spec["policy_hz"] == 20
            @test spec["substeps"] == 3
            @test spec["action"]["dtype"] == "float32"
        end

        @testset "reset(4) observation shape" begin
            ep = reset!(env; seed = 1234, agent_count = 4)
            @test ep.episode_id >= 1
            @test length(ep.observations) == 4
            @test all(o -> o isa Vector{Float32} && length(o) == 23, ep.observations)
            @test ep.active_mask == [1, 1, 1, 1]
            @test ep.info["seed"] == 1234
        end

        @testset "rollout of at least 1000 valid steps" begin
            total = 0
            episodes = 1
            all_valid = true
            reset!(env; seed = 2024, agent_count = 4)
            actions = zeros(4, 4)
            while total < 1000
                res = step!(env, actions)
                total += 1
                all_valid &= length(res.observations) == 4
                all_valid &= all(o -> length(o) == 23, res.observations)
                all_valid &= length(res.rewards) == 4
                all_valid &= length(res.active_mask) == 4
                if res.terminated || res.truncated
                    reset!(env; seed = 2024 + episodes, agent_count = 4)
                    episodes += 1
                end
            end
            @test total >= 1000
            @test all_valid
            println("  rollout: $total steps across $episodes episode(s)")
        end

        @testset "episode ids increase; stale ids are rejected" begin
            r1 = reset!(env; seed = 7, agent_count = 2)
            old_id = r1.episode_id
            r2 = reset!(env; seed = 7, agent_count = 2)
            @test r2.episode_id > old_id
            env.episode_id = old_id  # deliberately stale
            err = try
                step!(env, zeros(2, 4))
                nothing
            catch e
                e
            finally
                env.episode_id = r2.episode_id
            end
            @test err isa GodotServerError
            @test err.code == "STALE_EPISODE"
        end

        @testset "wrong action width rejected client-side" begin
            reset!(env; seed = 11, agent_count = 3)
            @test_throws ArgumentError step!(env, zeros(3, 3))
            @test_throws ArgumentError step!(env, zeros(2, 4))
            @test_throws ArgumentError step!(env, [[0, 0, 0, NaN], [0, 0, 0, 0], [0, 0, 0, 0]])
        end

        @testset "determinism via state_hash" begin
            rng = MersenneTwister(1234)
            action_seq = [[(rand(rng, 4) .* 2 .- 1) for _ in 1:4] for _ in 1:200]
            hashes = map(1:2) do run_idx
                reset!(env; seed = 42, agent_count = 4)
                run_hashes = String[]
                for actions in action_seq
                    res = step!(env, actions)
                    push!(run_hashes, res.info["state_hash"])
                    (res.terminated || res.truncated) && break
                end
                run_hashes
            end
            @test !isempty(hashes[1])
            @test hashes[1] == hashes[2]
            println("  determinism: $(length(hashes[1])) steps, " *
                    "final state_hash $(hashes[1][end])")
        end

        @testset "benchmark (informational)" begin
            for n in (1, 4, 16)
                reset_perf!(env)
                reset!(env; seed = 99, agent_count = n)
                steps = 0
                while steps < 100
                    res = step!(env, zeros(n, 4))
                    steps += 1
                    if res.terminated || res.truncated
                        reset!(env; seed = 99, agent_count = n)
                    end
                end
                print_perf(env; label = "benchmark agents=$n (~100 steps)")
                @test env.perf.step_count >= 100
            end
        end

        close(env)

        @testset "malformed raw bytes" begin
            # Main env is closed, so the single client slot is free.
            raw = Sockets.connect(ip"127.0.0.1", port)
            write(raw, encode_frame(codeunits("definitely not json {{{")))
            got = try
                hdr = read_exact(raw, 4, time() + 5.0)
                n = Int(ntoh(reinterpret(UInt32, hdr[1:4])[1]))
                JSON.parse(String(read_exact(raw, n, time() + 5.0)))
            catch e
                e isa GodotConnectionError ? nothing : rethrow()
            end
            if got === nothing
                # Acceptable per protocol: the server closed the connection.
                @test true
            else
                @test got["ok"] == false
                @test got["request_id"] === nothing
                @test got["error"]["code"] == "MALFORMED_MESSAGE"
            end
            close(raw)
        end
    end
end

const GODOT_BIN = get(ENV, "GODOT", "godot")
const GODOT_PATH = Sys.which(GODOT_BIN)
const RL_SERVER_SCRIPT = normpath(joinpath(@__DIR__, "..", "..", "simulator",
                                           "src", "networking", "rl_server.gd"))

if GODOT_PATH === nothing
    @warn "godot binary not found (looked for `$GODOT_BIN`; set the GODOT env " *
          "var to override) — skipping Godot integration tests"
    @test_skip "godot not available; integration tests skipped"
elseif !isfile(RL_SERVER_SCRIPT)
    @warn "RL server script not found at $RL_SERVER_SCRIPT (the Godot-side " *
          "server is not implemented yet) — skipping Godot integration tests"
    @test_skip "RL server script not present; integration tests skipped"
else
    run_integration_tests(GODOT_PATH)
end
