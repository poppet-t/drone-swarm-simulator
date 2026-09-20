"""
    DroneSwarmRL

Julia client for the Godot drone-swarm RL TCP bridge (protocol version 1;
see `docs/network_protocol.md`). The Godot server is authoritative for
episode state, dynamics, rewards, and agent ordering; this package submits
batched actions over a length-framed JSON/TCP connection.

Typical usage:

    env = GodotSwarmEnv("127.0.0.1", 9100)
    connect!(env)
    hello!(env)
    spec = get_spec!(env)
    ep = reset!(env; seed = 1234, agent_count = 4)
    res = step!(env, zeros(4, 4))
    close(env)
"""
module DroneSwarmRL

using Sockets
using JSON
using Printf

include("Protocol.jl")
include("GodotSwarmEnv.jl")

export GodotSwarmEnv, connect!, hello!, get_spec!, reset!, step!, ping!,
       PerfStats, reset_perf!, print_perf,
       encode_frame, FrameDecoder, feed!, build_request, validate_response, read_exact,
       GodotServerError, ProtocolFramingError, GodotConnectionError

end # module
