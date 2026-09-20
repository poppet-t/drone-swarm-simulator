# GodotSwarmEnv — TCP client for the Godot RL server (protocol version 1).

"""
    PerfStats

Cumulative client-side timing instrumentation for a [`GodotSwarmEnv`](@ref),
in nanoseconds (except `server_step_usec`, which is the server-measured
`info["step_time_usec"]` accumulated over STEP responses, in microseconds).
Use [`reset_perf!`](@ref) to zero and [`print_perf`](@ref) to display.
"""
mutable struct PerfStats
    serialize_ns::Int64      # JSON encode + framing
    send_ns::Int64           # socket write
    receive_ns::Int64        # waiting for + reading the response frame
    roundtrip_ns::Int64      # total request round trip
    server_step_usec::Int64  # sum of info["step_time_usec"] over STEP responses
    count::Int               # completed request round trips
    step_count::Int          # completed STEP round trips
end
PerfStats() = PerfStats(0, 0, 0, 0, 0, 0, 0)

"""
    GodotSwarmEnv(host="127.0.0.1", port=9100; timeout_s=10.0)

Client for the Godot RL TCP bridge. Construct, then [`connect!`](@ref),
[`hello!`](@ref) (mandatory first command), [`get_spec!`](@ref),
[`reset!`](@ref), [`step!`](@ref), and finally `close(env)`.

The env never reconnects silently: any `GodotConnectionError` marks it closed,
and recovering requires an explicit `connect!` (followed by `hello!` and
`reset!` — old episode IDs are stale on the server). One batched STEP request
is sent per swarm step, never one request per drone.
"""
mutable struct GodotSwarmEnv
    socket::Union{Nothing,TCPSocket}
    host::String
    port::Int
    protocol_version::Int
    next_request_id::Int
    episode_id::Union{Nothing,Int}
    spec::Union{Nothing,Dict{String,Any}}
    last_observation::Union{Nothing,Vector{Vector{Float32}}}
    closed::Bool
    observation_version::Int      # observation contract of the live episode
    timeout_s::Float64            # socket operation timeout, default 10.0
    perf::PerfStats
    # Persistent response reader (started by connect!): one long-lived task
    # decodes frames off the event loop into `inbox`; `_recv_frame` waits on
    # `inbox_cv` for instant wakeup instead of polling. Threads.Condition, NOT
    # a plain Condition: its wait() atomically releases the associated lock
    # during the wait, so the reader can lock/notify while _recv_frame parks.
    reader_task::Union{Nothing,Task}
    inbox_cv::Threads.Condition
    inbox::Vector{Vector{UInt8}}
    reader_error::Union{Nothing,Exception}
end

function GodotSwarmEnv(host::AbstractString = "127.0.0.1", port::Integer = 9100;
                       timeout_s::Real = 10.0)
    return GodotSwarmEnv(nothing, String(host), Int(port), PROTOCOL_VERSION, 0,
                         nothing, nothing, nothing, true, 1, Float64(timeout_s),
                         PerfStats(), nothing, Threads.Condition(),
                         Vector{Vector{UInt8}}(), nothing)
end

# Mark the env closed, drop the socket, and throw GodotConnectionError(msg).
function _mark_dead!(env::GodotSwarmEnv, msg::AbstractString)
    env.closed = true
    sock = env.socket
    env.socket = nothing
    sock === nothing || close(sock)
    throw(GodotConnectionError(msg))
end

# Persistent response reader: one long-lived task blocks on `readavailable`
# (which parks on the event loop; a yield() polling loop would never pump it)
# and pushes every complete frame into `inbox`. Started once per connection by
# [`connect!`](@ref); any failure is recorded in `reader_error` and surfaced
# to the waiting `_recv_frame`.
function _start_reader!(env::GodotSwarmEnv)
    sock = env.socket
    env.reader_task = @async begin
        dec = FrameDecoder()
        try
            while true
                chunk = readavailable(sock)
                isempty(chunk) && throw(EOFError())
                frames = feed!(dec, chunk)
                isempty(frames) && continue
                lock(env.inbox_cv) do
                    append!(env.inbox, frames)
                    notify(env.inbox_cv)
                end
            end
        catch e
            e isa InterruptException && return
            lock(env.inbox_cv) do
                env.reader_error = e isa ProtocolFramingError ? e : EOFError()
                notify(env.inbox_cv)
            end
        end
    end
    return nothing
end

# Receive exactly one response frame before the absolute deadline. Waits on
# the reader's condition variable (instant wakeup on arrival — no timedwait
# polling quantization) with the deadline enforced by a watchdog Timer that
# notifies the same condition. Any failure marks the env dead (the response
# stream may be desynchronised afterwards).
function _recv_frame(env::GodotSwarmEnv, deadline::Real)::Vector{UInt8}
    watchdog = Timer(max(deadline - time(), 0.0)) do _
        lock(env.inbox_cv) do
            notify(env.inbox_cv)
        end
    end
    lock(env.inbox_cv)
    try
        while true
            if !isempty(env.inbox)
                frame = popfirst!(env.inbox)
                if !isempty(env.inbox)
                    empty!(env.inbox)
                    _mark_dead!(env,
                        "received multiple frames within one request/response cycle")
                end
                return frame
            end
            if env.reader_error !== nothing
                err = env.reader_error
                err isa ProtocolFramingError && throw(err)  # caller decides; fatal
                _mark_dead!(env,
                    "connection closed by peer while waiting for a response ($(sprint(showerror, err)))")
            end
            deadline - time() <= 0.0 &&
                _mark_dead!(env, "timeout waiting for a response after $(env.timeout_s) s")
            wait(env.inbox_cv)
        end
    finally
        unlock(env.inbox_cv)
        close(watchdog)
    end
end

# Serialize, frame, send, and await the matching response. Returns the
# validated `result` Dict. Errors:
#   ok == false            -> GodotServerError (env stays usable)
#   framing/garbage/socket -> ProtocolFramingError / GodotConnectionError (env closed)
function _roundtrip(env::GodotSwarmEnv, command::AbstractString,
                    payload = Dict{String,Any}(); episode_id = nothing)
    sock = env.socket
    (sock === nothing || !isopen(sock)) &&
        throw(GodotConnectionError("not connected; call connect!(env) first"))
    rid = env.next_request_id
    env.next_request_id += 1
    request = build_request(command, rid; protocol_version = env.protocol_version,
                            episode_id = episode_id, payload = payload)
    t0 = time_ns()
    frame = encode_frame(codeunits(JSON.json(request)))
    t1 = time_ns()
    try
        write(sock, frame)  # TCPSocket writes go straight to the OS; no flush needed
    catch e
        _mark_dead!(env, "failed to send $command request: $(e)")
    end
    t2 = time_ns()
    resp_bytes = try
        _recv_frame(env, time() + env.timeout_s)
    catch e
        e isa ProtocolFramingError ? _mark_dead!(env, sprint(showerror, e)) : rethrow()
    end
    t3 = time_ns()
    perf = env.perf
    perf.serialize_ns += t1 - t0
    perf.send_ns      += t2 - t1
    perf.receive_ns   += t3 - t2
    perf.roundtrip_ns += t3 - t0
    perf.count        += 1
    resp = try
        JSON.parse(String(resp_bytes))
    catch e
        _mark_dead!(env, "unparseable response to $command (request_id=$rid): $(e)")
    end
    try
        return validate_response(resp, rid; protocol_version = env.protocol_version)
    catch e
        # A structurally invalid envelope desynchronises the stream; a normal
        # server error (GodotServerError) leaves the connection healthy.
        e isa GodotConnectionError && _mark_dead!(env, sprint(showerror, e))
        rethrow()
    end
end

"""
    connect!(env::GodotSwarmEnv)

Open the TCP connection to `env.host:env.port`, respecting `env.timeout_s`.
Throws `GodotConnectionError` on failure or if already connected — close the
env first to reconnect. A fresh connection must be followed by [`hello!`](@ref)
and [`reset!`](@ref) before stepping.
"""
function connect!(env::GodotSwarmEnv)
    if env.socket !== nothing && isopen(env.socket)
        throw(GodotConnectionError(
            "already connected to $(env.host):$(env.port); call close(env) before reconnecting"))
    end
    task = @async Sockets.connect(env.host, env.port)
    if timedwait(() -> istaskdone(task), env.timeout_s; pollint = 0.005) == :timed_out
        @async begin  # best effort: drop the socket if the connect ever completes
            try
                close(fetch(task))
            catch
            end
        end
        env.closed = true
        throw(GodotConnectionError(
            "timeout connecting to $(env.host):$(env.port) after $(env.timeout_s) s"))
    end
    local sock
    try
        sock = fetch(task)
    catch e
        env.closed = true
        throw(GodotConnectionError(
            "failed to connect to $(env.host):$(env.port): $(sprint(showerror, e))"))
    end
    env.socket = sock
    env.closed = false
    # Latency-sensitive RPC: disable Nagle so small request frames are not
    # held behind unacked segments (the server sets TCP_NODELAY too).
    if isdefined(Sockets, :nodelay!)
        Sockets.nodelay!(sock)
    end
    empty!(env.inbox)
    env.reader_error = nothing
    _start_reader!(env)
    env.episode_id = nothing
    env.last_observation = nothing
    return env
end

"""
    hello!(env; client_name="DroneSwarmRL.jl", client_version="0.1.0")

Perform the mandatory HELLO handshake (must be the first command on a
connection). Returns the server result Dict (`server_name`, `godot_version`,
`protocol_version`, `capabilities`).
"""
function hello!(env::GodotSwarmEnv; client_name::AbstractString = "DroneSwarmRL.jl",
                client_version::AbstractString = "0.1.0")
    payload = Dict{String,Any}(
        "client_name" => String(client_name),
        "client_version" => String(client_version),
        "supported_protocol_versions" => [env.protocol_version],
    )
    return _roundtrip(env, "HELLO", payload; episode_id = nothing)
end

"""
    get_spec!(env::GodotSwarmEnv)

Fetch the environment spec (action/observation shapes, agent limits, rates)
and cache it in `env.spec`. Returns the spec Dict.
"""
function get_spec!(env::GodotSwarmEnv)
    result = _roundtrip(env, "GET_SPEC", Dict{String,Any}(); episode_id = nothing)
    env.spec = Dict{String,Any}(result)  # result may be any AbstractDict (JSON.Object)
    return env.spec
end

_to_f32_matrix(obs) = [Float32.(row) for row in obs]

"""
    reset!(env; seed, scenario="waypoint", agent_count=1,
           observation_version=nothing, options=Dict())

Start a new episode. Returns a NamedTuple `(episode_id, observations,
active_mask, info)` with `observations::Vector{Vector{Float32}}` (one
observation per agent, in stable spawn order). Updates `env.episode_id` and
`env.last_observation`.

`observation_version` selects the episode's observation contract when set
(e.g. `2`; the server default is 1). The chosen version is echoed by the
server and cached on `env.observation_version`.
"""
function reset!(env::GodotSwarmEnv; seed::Integer,
                scenario::AbstractString = "waypoint",
                agent_count::Integer = 1,
                observation_version::Union{Nothing,Integer} = nothing,
                options = Dict{String,Any}())
    payload = Dict{String,Any}(
        "seed" => Int(seed),
        "scenario" => String(scenario),
        "agent_count" => Int(agent_count),
        "options" => options,
    )
    if observation_version !== nothing
        payload["observation_version"] = Int(observation_version)
    end
    result = _roundtrip(env, "RESET", payload; episode_id = nothing)
    episode_id = Int(result["episode_id"])
    observations = _to_f32_matrix(result["observations"])
    active_mask = Int.(result["active_mask"])
    info = get(result, "info", Dict{String,Any}())
    env.episode_id = episode_id
    env.last_observation = observations
    env.observation_version = get(result, "observation_version",
                                  something(observation_version, 1))
    return (episode_id = episode_id, observations = observations,
            active_mask = active_mask, info = info)
end

# Client-side action validation, run BEFORE the socket is touched. Returns
# actions as Vector{Vector{Float32}} (n_agents rows of width 4, all finite).
function _validate_actions(actions, n_agents::Int)::Vector{Vector{Float32}}
    rows = if actions isa AbstractMatrix
        size(actions, 2) == 4 || throw(ArgumentError(
            "action matrix must have 4 columns (accel_x, accel_y, accel_z, yaw_rate); " *
            "got size $(size(actions))"))
        size(actions, 1) == n_agents || throw(ArgumentError(
            "expected $n_agents action rows (current agent count), got $(size(actions, 1))"))
        [actions[i, :] for i in 1:n_agents]
    elseif actions isa AbstractVector && all(r -> r isa AbstractVector, actions)
        length(actions) == n_agents || throw(ArgumentError(
            "expected $n_agents actions (current agent count), got $(length(actions))"))
        collect(actions)
    else
        throw(ArgumentError(
            "actions must be an $(n_agents)×4 matrix or a vector of $n_agents 4-element vectors"))
    end
    out = Vector{Vector{Float32}}(undef, n_agents)
    for i in 1:n_agents
        row = rows[i]
        length(row) == 4 || throw(ArgumentError(
            "action $i has width $(length(row)); expected 4 (accel_x, accel_y, accel_z, yaw_rate)"))
        for (j, v) in enumerate(row)
            v isa Real || throw(ArgumentError(
                "action ($i,$j) = $(repr(v)) is not a number"))
            isfinite(Float64(v)) || throw(ArgumentError(
                "action ($i,$j) = $(repr(v)) is not finite"))
        end
        out[i] = [Float32(v) for v in row]
    end
    return out
end

"""
    step!(env::GodotSwarmEnv, actions)

Step the whole swarm with one batched STEP request. `actions` is an
`n_agents × 4` matrix (one row per agent) or a vector of `n_agents` 4-element
vectors, components in [-1, 1] semantics (the server clamps).

Validated client-side before anything is sent — outer length must equal the
current agent count, inner width must be 4, all components finite — throwing
`ArgumentError` without touching the socket on violation.

Returns a NamedTuple `(observations, rewards, team_reward, terminated,
truncated, active_mask, info)`. Server error responses (e.g. `STALE_EPISODE`,
`EPISODE_ENDED`) throw `GodotServerError` and leave `env.episode_id`
untouched.
"""
function step!(env::GodotSwarmEnv, actions)
    (env.episode_id === nothing || env.last_observation === nothing) &&
        throw(ArgumentError("no active episode; call reset! before step!"))
    n_agents = length(env.last_observation)
    acts = _validate_actions(actions, n_agents)
    result = _roundtrip(env, "STEP", Dict{String,Any}("actions" => acts);
                        episode_id = env.episode_id)
    observations = _to_f32_matrix(result["observations"])
    rewards = Float32.(result["rewards"])
    team_reward = Float32(result["team_reward"])
    terminated = Bool(result["terminated"])
    truncated = Bool(result["truncated"])
    active_mask = Int.(result["active_mask"])
    info = get(result, "info", Dict{String,Any}())
    env.last_observation = observations
    env.perf.step_count += 1
    env.perf.server_step_usec += Int(get(info, "step_time_usec", 0))
    return (observations = observations, rewards = rewards, team_reward = team_reward,
            terminated = terminated, truncated = truncated,
            active_mask = active_mask, info = info)
end

"""
    ping!(env::GodotSwarmEnv)

Send PING. Returns the result Dict (`pong`, `server_time_msec`, `episode_id`).
"""
ping!(env::GodotSwarmEnv) = _roundtrip(env, "PING", Dict{String,Any}(); episode_id = nothing)

"""
    close(env::GodotSwarmEnv)

Send CLOSE (if still connected) and close the socket. Idempotent. Afterwards
`env.episode_id` and `env.last_observation` are cleared; reuse requires an
explicit [`connect!`](@ref).
"""
function Base.close(env::GodotSwarmEnv)
    if env.socket !== nothing && isopen(env.socket)
        try
            _roundtrip(env, "CLOSE", Dict{String,Any}(); episode_id = nothing)
        catch
            # Server may already be gone, or a previous failure killed the
            # stream — close the socket regardless.
        end
    end
    env.socket === nothing || close(env.socket)
    env.socket = nothing
    env.closed = true
    env.episode_id = nothing
    env.last_observation = nothing
    return nothing
end

"""
    reset_perf!(env::GodotSwarmEnv)

Zero the [`PerfStats`](@ref) counters on `env`.
"""
reset_perf!(env::GodotSwarmEnv) = (env.perf = PerfStats(); nothing)

"""
    print_perf(env::GodotSwarmEnv; label="")

Print mean and total times per phase: serialization, socket send, socket
receive, server-side env step (from `info["step_time_usec"]`), and full
request round trip.
"""
function print_perf(env::GodotSwarmEnv; label::AbstractString = "")
    p = env.perf
    hdr = isempty(label) ? "PerfStats" : "PerfStats — $label"
    if p.count == 0
        println("$hdr: no completed requests")
        return nothing
    end
    n = p.count
    ns_mean(x) = x / n / 1e3     # ns -> mean µs
    ns_total(x) = x / 1e6        # ns -> total ms
    @printf("%s (%d round trips, %d steps)\n", hdr, n, p.step_count)
    @printf("  %-14s %12s %12s\n", "phase", "mean", "total")
    @printf("  %-14s %10.1f us %10.3f ms\n", "serialization", ns_mean(p.serialize_ns), ns_total(p.serialize_ns))
    @printf("  %-14s %10.1f us %10.3f ms\n", "socket send", ns_mean(p.send_ns), ns_total(p.send_ns))
    @printf("  %-14s %10.1f us %10.3f ms\n", "socket receive", ns_mean(p.receive_ns), ns_total(p.receive_ns))
    if p.step_count > 0
        @printf("  %-14s %10.1f us %10.3f ms\n", "server step",
                p.server_step_usec / p.step_count, p.server_step_usec / 1e3)
    end
    @printf("  %-14s %10.1f us %10.3f ms\n", "round trip", ns_mean(p.roundtrip_ns), ns_total(p.roundtrip_ns))
    return nothing
end
