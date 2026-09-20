# Pure-Julia protocol tests — no Godot server needed.
# Includes a loopback mock server exercising the real client end to end.

using Test
using Sockets
using JSON
using DroneSwarmRL

const MAX_BYTES = DroneSwarmRL.MAX_MESSAGE_BYTES

@testset "framing" begin
    @testset "round-trip and big-endianness" begin
        payload = rand(UInt8, 258)
        frame = encode_frame(payload)
        # 258 = 0x00000102, big-endian prefix
        @test frame[1:4] == UInt8[0x00, 0x00, 0x01, 0x02]
        @test frame[5:end] == payload
        @test length(frame) == 4 + 258

        dec = FrameDecoder()
        @test feed!(dec, frame) == [payload]

        # 1-byte payload
        f1 = encode_frame(UInt8[0xAB])
        @test f1 == UInt8[0x00, 0x00, 0x00, 0x01, 0xAB]
    end

    @testset "empty payload is a framing violation" begin
        @test_throws ProtocolFramingError encode_frame(UInt8[])
        dec = FrameDecoder()
        @test_throws ProtocolFramingError feed!(dec, UInt8[0x00, 0x00, 0x00, 0x00])
    end

    @testset "oversized length is a framing violation" begin
        @test_throws ProtocolFramingError encode_frame(zeros(UInt8, MAX_BYTES + 1))
        dec = FrameDecoder()
        # header declaring 1 MiB + 1 = 0x00100001
        @test_throws ProtocolFramingError feed!(dec, UInt8[0x00, 0x10, 0x00, 0x01])
        # exactly 1 MiB is legal
        dec_ok = FrameDecoder()
        big = encode_frame(zeros(UInt8, MAX_BYTES))
        @test feed!(dec_ok, big) == [zeros(UInt8, MAX_BYTES)]
    end

    @testset "fragmented 4-byte header" begin
        payload = codeunits("hello")
        frame = encode_frame(payload)
        dec = FrameDecoder()
        for cut in 1:3
            d = FrameDecoder()
            @test feed!(d, frame[1:cut]) == []
            @test feed!(d, frame[(cut + 1):end]) == [payload]
        end
        # byte-by-byte header delivery
        d = FrameDecoder()
        @test feed!(d, frame[1:1]) == []
        @test feed!(d, frame[2:2]) == []
        @test feed!(d, frame[3:3]) == []
        @test feed!(d, frame[4:4]) == []
        @test feed!(d, frame[5:end]) == [payload]
    end

    @testset "fragmented payload" begin
        payload = codeunits("a longer payload, split mid-body")
        frame = encode_frame(payload)
        dec = FrameDecoder()
        mid = 4 + (length(payload) ÷ 2)
        @test feed!(dec, frame[1:mid]) == []
        @test feed!(dec, frame[(mid + 1):end]) == [payload]
    end

    @testset "multiple frames in one feed, and empty feeds" begin
        p1, p2, p3 = codeunits("one"), codeunits("two"), codeunits("three")
        blob = vcat(encode_frame(p1), encode_frame(p2), encode_frame(p3))
        dec = FrameDecoder()
        @test feed!(dec, UInt8[]) == []
        @test feed!(dec, blob) == [p1, p2, p3]
        # frame split across two feeds, followed by another frame
        dec2 = FrameDecoder()
        @test feed!(dec2, blob[1:6]) == []
        out = feed!(dec2, blob[7:end])
        @test out == [p1, p2, p3]
        # decoder is reusable after delivering frames
        @test feed!(dec2, encode_frame(p1)) == [p1]
    end
end

@testset "envelope" begin
    @testset "build_request" begin
        req = build_request("STEP", 42; episode_id = 17,
                            payload = Dict{String,Any}("actions" => [[0.0, 0.0, 0.0, 0.0]]))
        @test req["protocol_version"] == 1
        @test req["request_id"] == 42
        @test req["command"] == "STEP"
        @test req["episode_id"] == 17
        @test req["payload"]["actions"] == [[0.0, 0.0, 0.0, 0.0]]
        # JSON round trip keeps the envelope shape; episode_id nothing -> null
        req2 = build_request("RESET", 1; episode_id = nothing)
        parsed = JSON.parse(JSON.json(req2))
        @test parsed["episode_id"] === nothing
        @test parsed["command"] == "RESET"
    end

    @testset "validate_response ok / error round-trip" begin
        ok_resp = Dict{String,Any}("protocol_version" => 1, "request_id" => 7,
                                   "ok" => true, "episode_id" => 3,
                                   "result" => Dict{String,Any}("pong" => true),
                                   "error" => nothing)
        @test validate_response(ok_resp, 7) == Dict{String,Any}("pong" => true)

        err_resp = Dict{String,Any}("protocol_version" => 1, "request_id" => 8,
                                    "ok" => false, "episode_id" => 3, "result" => nothing,
                                    "error" => Dict{String,Any}("code" => "STALE_EPISODE",
                                                                "message" => "episode 2 is stale"))
        err = try
            validate_response(err_resp, 8)
            nothing
        catch e
            e
        end
        @test err isa GodotServerError
        @test err.code == "STALE_EPISODE"
        @test err.msg == "episode 2 is stale"
        @test err.request_id == 8
        @test occursin("STALE_EPISODE: episode 2 is stale", sprint(show, err))

        @test_throws GodotConnectionError validate_response(
            Dict{String,Any}("protocol_version" => 2, "request_id" => 7,
                             "ok" => true, "result" => Dict{String,Any}()), 7)
        @test_throws GodotConnectionError validate_response(
            Dict{String,Any}("protocol_version" => 1, "request_id" => 999,
                             "ok" => true, "result" => Dict{String,Any}()), 7)
        @test_throws GodotConnectionError validate_response(
            Dict{String,Any}("protocol_version" => 1, "request_id" => nothing,
                             "ok" => true, "result" => Dict{String,Any}()), 7)
        @test_throws GodotConnectionError validate_response("not a dict", 7)
        @test_throws GodotConnectionError validate_response(
            Dict{String,Any}("protocol_version" => 1, "request_id" => 7,
                             "ok" => false, "error" => nothing), 7)
    end
end

# ---------------------------------------------------------------------------
# Loopback mock server: framing + a few canned responses, and the real
# GodotSwarmEnv client driven against it.
#
# Mock conventions:
#  * RESET honours payload["agent_count"] and hands out increasing episode ids.
#  * STEP replies INVALID_ACTION_SHAPE for wrong width / wrong outer length,
#    or when any action component is exactly 42.0 (a magic value the client
#    passes through — it validates shape and finiteness only — letting us
#    exercise a server-side rejection of a client-side-valid request).
#  * command "TRIGGER_GARBAGE" gets a raw, unparseable reply (valid frame,
#    invalid JSON).
# ---------------------------------------------------------------------------

function _mock_read_request(io::IO)
    hdr = read(io, 4)  # may return short on client disconnect
    length(hdr) < 4 && throw(EOFError())
    n = Int(ntoh(reinterpret(UInt32, hdr)[1]))
    body = read(io, n)
    length(body) < n && throw(EOFError())
    JSON.parse(String(body))
end

function _mock_write(io::IO, msg::Dict{String,Any})
    write(io, encode_frame(codeunits(JSON.json(msg))))
end

function _mock_response(req, ok::Bool; result = nothing, err = nothing)
    return Dict{String,Any}(
        "protocol_version" => 1,
        "request_id" => get(req, "request_id", nothing),
        "ok" => ok,
        "episode_id" => get(req, "episode_id", nothing),
        "result" => result,
        "error" => err,
    )
end

function _mock_handle_client(sock::TCPSocket, state)
    try
        while isopen(sock)
            req = _mock_read_request(sock)
            state[:requests][] += 1
            cmd = get(req, "command", "")
            payload = get(req, "payload", Dict{String,Any}())
            if cmd == "HELLO"
                _mock_write(sock, _mock_response(req, true; result = Dict{String,Any}(
                    "server_name" => "MockRLServer", "godot_version" => "4.7.1.stable.official",
                    "protocol_version" => 1, "capabilities" => ["get_spec", "reset", "step"])))
            elseif cmd == "GET_SPEC"
                _mock_write(sock, _mock_response(req, true; result = Dict{String,Any}(
                    "action" => Dict{String,Any}("shape_per_agent" => [4], "dtype" => "float32",
                                                 "minimum" => -1.0, "maximum" => 1.0,
                                                 "names" => ["accel_x", "accel_y", "accel_z", "yaw_rate"]),
                    "observation" => Dict{String,Any}("shape_per_agent" => [23], "dtype" => "float32"),
                    "supports_variable_agents" => true,
                    "minimum_agents" => 1, "maximum_agents" => 16,
                    "scenarios" => ["waypoint"],
                    "physics_hz" => 60, "policy_hz" => 20, "substeps" => 3)))
            elseif cmd == "RESET"
                n = Int(get(payload, "agent_count", 1))
                state[:agent_count] = n
                state[:episode_id] += 1
                _mock_write(sock, _mock_response(req, true; result = Dict{String,Any}(
                    "episode_id" => state[:episode_id],
                    "observations" => [zeros(23) for _ in 1:n],
                    "active_mask" => ones(Int, n),
                    "info" => Dict{String,Any}("seed" => get(payload, "seed", 0), "steps" => 0))))
            elseif cmd == "STEP"
                state[:step_requests][] += 1
                actions = payload["actions"]
                bad_shape = length(actions) != state[:agent_count] ||
                            any(a -> !(a isa AbstractVector) || length(a) != 4, actions)
                magic = any(a -> a isa AbstractVector && any(v -> v == 42.0, a), actions)
                if bad_shape || magic
                    _mock_write(sock, _mock_response(req, false; err = Dict{String,Any}(
                        "code" => "INVALID_ACTION_SHAPE",
                        "message" => "mock rejection of $(length(actions)) actions")))
                else
                    n = state[:agent_count]
                    _mock_write(sock, _mock_response(req, true; result = Dict{String,Any}(
                        "episode_id" => state[:episode_id],
                        "observations" => [zeros(23) for _ in 1:n],
                        "rewards" => zeros(n),
                        "team_reward" => 0.0,
                        "terminated" => false, "truncated" => false,
                        "active_mask" => ones(Int, n),
                        "info" => Dict{String,Any}("steps" => state[:step_requests][],
                                                   "step_time_usec" => 100,
                                                   "state_hash" => "deadbeef"))))
                end
            elseif cmd == "TRIGGER_GARBAGE"
                # Valid frame, but the payload is not parseable JSON.
                write(sock, encode_frame(codeunits("this is not valid json {{{")))
            elseif cmd == "PING"
                _mock_write(sock, _mock_response(req, true; result = Dict{String,Any}(
                    "pong" => true, "server_time_msec" => 123456,
                    "episode_id" => state[:episode_id] > 0 ? state[:episode_id] : nothing)))
            elseif cmd == "CLOSE"
                _mock_write(sock, _mock_response(req, true;
                    result = Dict{String,Any}("closing" => true)))
                close(sock)
                break
            else
                _mock_write(sock, _mock_response(req, false; err = Dict{String,Any}(
                    "code" => "UNKNOWN_COMMAND", "message" => "mock does not know $cmd")))
            end
        end
    catch e
        (e isa EOFError || e isa Base.IOError) ||
            @warn "mock server connection error" exception = (e, catch_backtrace())
    finally
        try close(sock) catch end
    end
end

@testset "mock server (loopback)" begin
    port, listener = listenany(ip"127.0.0.1", 0)
    state = Dict{Symbol,Any}(:requests => Ref(0), :step_requests => Ref(0),
                             :agent_count => 0, :episode_id => 0)
    server_task = @async begin
        while isopen(listener)
            sock = accept(listener)
            @async _mock_handle_client(sock, state)
        end
    end
    try
        env = GodotSwarmEnv("127.0.0.1", Int(port); timeout_s = 5.0)

        @testset "connect / hello / get_spec" begin
            @test connect!(env) === env
            @test !env.closed
            @test_throws GodotConnectionError connect!(env)  # already connected

            hello = hello!(env)
            @test hello["server_name"] == "MockRLServer"
            @test hello["protocol_version"] == 1

            spec = get_spec!(env)
            @test env.spec === spec  # cached
            @test spec["action"]["shape_per_agent"] == [4]
            @test spec["observation"]["shape_per_agent"] == [23]

            pong = ping!(env)
            @test pong["pong"] == true
        end

        @testset "reset and valid step" begin
            ep = reset!(env; seed = 99, agent_count = 2)
            @test ep.episode_id == 1
            @test env.episode_id == 1
            @test length(ep.observations) == 2
            @test all(o -> o isa Vector{Float32} && length(o) == 23, ep.observations)
            @test ep.active_mask == [1, 1]

            res = step!(env, zeros(2, 4))
            @test length(res.observations) == 2
            @test res.rewards isa Vector{Float32}
            @test res.team_reward === 0.0f0
            @test res.terminated == false && res.truncated == false
            @test res.active_mask == [1, 1]
            @test res.info["step_time_usec"] == 100
            @test state[:step_requests][] == 1
            # perf instrumentation accumulated
            @test env.perf.count >= 5
            @test env.perf.step_count == 1
            @test env.perf.server_step_usec == 100
            @test env.perf.roundtrip_ns >= env.perf.serialize_ns
        end

        @testset "client-side action validation (no server interaction)" begin
            before = state[:step_requests][]
            @test_throws ArgumentError step!(env, zeros(2, 3))          # wrong width
            @test_throws ArgumentError step!(env, zeros(3, 4))          # wrong outer length
            @test_throws ArgumentError step!(env, [[0, 0, 0, 0, 0], [0, 0, 0, 0]])  # vector-of-vectors wrong width
            @test_throws ArgumentError step!(env, [[NaN, 0, 0, 0], [0, 0, 0, 0]])   # non-finite
            @test_throws ArgumentError step!(env, [[Inf, 0, 0, 0], [0, 0, 0, 0]])   # non-finite
            @test_throws ArgumentError step!(env, [["x", 0, 0, 0], [0, 0, 0, 0]])   # non-numeric
            @test_throws ArgumentError step!(env, 42)                              # nonsense type
            @test state[:step_requests][] == before  # the mock saw nothing
        end

        @testset "server-rejected step throws GodotServerError" begin
            ep_before = env.episode_id
            err = try
                # right shape (2 x 4, finite) but the mock rejects 42.0
                step!(env, [[42.0, 0, 0, 0], [0, 0, 0, 0]])
                nothing
            catch e
                e
            end
            @test err isa GodotServerError
            @test err.code == "INVALID_ACTION_SHAPE"
            @test env.episode_id == ep_before  # untouched after a server error
            @test !env.closed
        end

        @testset "garbage reply throws GodotConnectionError and marks closed" begin
            @test_throws GodotConnectionError DroneSwarmRL._roundtrip(
                env, "TRIGGER_GARBAGE", Dict{String,Any}())
            @test env.closed
            @test_throws GodotConnectionError ping!(env)  # not connected anymore
        end

        @testset "close is clean and idempotent" begin
            @test close(env) === nothing
            @test close(env) === nothing
            @test env.closed
            @test env.episode_id === nothing
            @test env.socket === nothing
        end

        @testset "fresh connection, clean close with CLOSE handshake" begin
            env2 = GodotSwarmEnv("127.0.0.1", Int(port); timeout_s = 5.0)
            connect!(env2)
            hello!(env2)
            reset!(env2; seed = 1, agent_count = 1)
            @test env2.episode_id == 2  # mock ids increase monotonically
            close(env2)
            close(env2)
            @test env2.closed
        end
    finally
        close(listener)
        # unblock accept() so the server task finishes
        try
            s = Sockets.connect(ip"127.0.0.1", port)
            close(s)
        catch
        end
    end
end

# Regression (Phase 3 receive-path rework): a server that accepts but never
# answers must surface as GodotConnectionError after timeout_s and mark the
# env closed — the watchdog wakes the condition wait, no polling involved.
@testset "silent server: response timeout marks env dead" begin
    port2, listener2 = listenany(ip"127.0.0.1", 0)
    sink_task = @async begin
        while isopen(listener2)
            sock = accept(listener2)
            @async try  # swallow requests, never reply
                while true
                    isempty(readavailable(sock)) && break
                end
            catch
            end
        end
    end
    try
        env_s = GodotSwarmEnv("127.0.0.1", Int(port2); timeout_s = 0.25)
        connect!(env_s)
        t0 = time()
        err = try
            ping!(env_s)
            nothing
        catch e
            e
        end
        elapsed = time() - t0
        @test err isa GodotConnectionError
        @test occursin("timeout", sprint(showerror, err))
        @test 0.2 <= elapsed <= 5.0
        @test env_s.closed
        @test_throws GodotConnectionError ping!(env_s)
    finally
        close(listener2)
        try
            s = Sockets.connect(ip"127.0.0.1", port2)
            close(s)
        catch
        end
    end
end
