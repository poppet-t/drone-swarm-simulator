# Demo rollout client: drives the swarm with a uniform random policy.
#
# Usage (from the repo root):
#   julia --project=julia julia/scripts/random_policy_client.jl \
#       [--host 127.0.0.1] [--port 9100] [--seed 1234] [--agents 4] [--steps 200]
#
# Exits non-zero on error.

using DroneSwarmRL
using Random
using Printf

const DEFAULTS = Dict{String,String}(
    "--host" => "127.0.0.1",
    "--port" => "9100",
    "--seed" => "1234",
    "--agents" => "4",
    "--steps" => "200",
)

function parse_args(args)
    opts = copy(DEFAULTS)
    # Tolerate a leading "--" (conventional separator between the script and
    # its arguments: `julia script.jl -- --port 9100`).
    args = (!isempty(args) && args[1] == "--") ? args[2:end] : args
    i = 1
    while i <= length(args)
        a = args[i]
        if a in ("-h", "--help")
            println("usage: julia --project=julia julia/scripts/random_policy_client.jl " *
                    "[--host H] [--port P] [--seed S] [--agents N] [--steps N]")
            exit(0)
        elseif haskey(opts, a) && i < length(args)
            opts[a] = args[i + 1]
            i += 2
        elseif startswith(a, "--") && contains(a, "=")
            # --key=value form
            key, value = split(a, "="; limit = 2)
            if haskey(opts, key)
                opts[key] = value
                i += 1
            else
                println(stderr, "unknown argument: $key")
                exit(2)
            end
        else
            println(stderr, "unknown or incomplete argument: $a")
            exit(2)
        end
    end
    return opts
end

function main()
    opts = parse_args(ARGS)
    host = opts["--host"]
    port = parse(Int, opts["--port"])
    seed = parse(Int, opts["--seed"])
    agents = parse(Int, opts["--agents"])
    steps = parse(Int, opts["--steps"])
    rng = MersenneTwister(seed)

    env = GodotSwarmEnv(host, port)
    failed = false
    try
        connect!(env)
        hello = hello!(env)
        @printf("HELLO: %s (godot %s, protocol v%d)\n",
                get(hello, "server_name", "?"), get(hello, "godot_version", "?"),
                get(hello, "protocol_version", -1))
        spec = get_spec!(env)
        println("SPEC:")
        for k in sort!(collect(keys(spec)))
            println("  $k = $(spec[k])")
        end

        episode = reset!(env; seed = seed, agent_count = agents)
        episode_len = 0
        episode_return = 0.0
        for step in 1:steps
            actions = [(rand(rng, 4) .* 2 .- 1) for _ in 1:agents]
            res = step!(env, actions)
            episode_len += 1
            episode_return += res.team_reward
            if res.terminated || res.truncated
                @printf("episode %d: %d steps, return %.3f (%s)\n",
                        episode.episode_id, episode_len, episode_return,
                        res.terminated ? "terminated" : "truncated")
                episode = reset!(env; seed = seed + episode.episode_id, agent_count = agents)
                episode_len = 0
                episode_return = 0.0
            end
        end
        if episode_len > 0
            @printf("episode %d: %d steps, return %.3f (cut off at --steps=%d)\n",
                    episode.episode_id, episode_len, episode_return, steps)
        end
        println()
        print_perf(env; label = "random_policy_client agents=$agents steps=$steps")
    catch e
        failed = true
        @error "random policy client failed" exception = (e, catch_backtrace())
    finally
        close(env)
    end
    failed && exit(1)
    return nothing
end

main()
