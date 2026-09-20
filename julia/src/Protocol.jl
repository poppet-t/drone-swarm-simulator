# Length-framed JSON protocol (protocol version 1) — see docs/network_protocol.md.
#
# Framing: 4-byte big-endian uint32 payload length + UTF-8 JSON payload.
# Max payload: 1 MiB. Zero length / oversize are framing violations.

"""Maximum payload size in bytes (`MAX_MESSAGE_BYTES` from the protocol spec)."""
const MAX_MESSAGE_BYTES = 1_048_576

"""Protocol version implemented by this client."""
const PROTOCOL_VERSION = 1

"""
    GodotServerError <: Exception

The server answered a request with `ok == false`. Carries the protocol error
`code` (e.g. `"STALE_EPISODE"`), the human-readable `msg`, and the
`request_id` of the failed request. Prints as `code: message`.
"""
struct GodotServerError <: Exception
    code::String
    msg::String
    request_id::Union{Nothing,Int}
end
GodotServerError(code::AbstractString, msg::AbstractString) =
    GodotServerError(code, msg, nothing)

function Base.show(io::IO, e::GodotServerError)
    print(io, "GodotServerError: ", e.code, ": ", e.msg)
    e.request_id === nothing || print(io, " (request_id=", e.request_id, ")")
end

"""
    ProtocolFramingError <: Exception

A framing violation: zero length, length > 1 MiB, or an attempt to encode
such a frame. Unrecoverable for the connection that produced it.
"""
struct ProtocolFramingError <: Exception
    msg::String
end
Base.show(io::IO, e::ProtocolFramingError) = print(io, "ProtocolFramingError: ", e.msg)

"""
    GodotConnectionError <: Exception

A socket-level failure: connect/read/write error, timeout, closed peer, or a
response that cannot be reconciled with the request (garbage bytes, wrong
`request_id`, structurally invalid envelope).
"""
struct GodotConnectionError <: Exception
    msg::String
end
Base.show(io::IO, e::GodotConnectionError) = print(io, "GodotConnectionError: ", e.msg)

"""
    encode_frame(payload::AbstractVector{UInt8})::Vector{UInt8}

Frame `payload` as 4-byte big-endian length prefix + payload bytes.
Throws `ProtocolFramingError` for empty or oversized (> 1 MiB) payloads.
"""
function encode_frame(payload::AbstractVector{UInt8})::Vector{UInt8}
    n = length(payload)
    n == 0 && throw(ProtocolFramingError("cannot encode a zero-length frame"))
    n > MAX_MESSAGE_BYTES && throw(ProtocolFramingError(
        "payload of $n bytes exceeds MAX_MESSAGE_BYTES ($MAX_MESSAGE_BYTES)"))
    frame = Vector{UInt8}(undef, 4 + n)
    copyto!(frame, 1, reinterpret(UInt8, [hton(UInt32(n))]), 1, 4)
    copyto!(frame, 5, payload, 1, n)
    return frame
end
encode_frame(payload::AbstractString) = encode_frame(codeunits(payload))

# Decode and validate a big-endian 4-byte frame length.
function _frame_length_from_header(hdr::AbstractVector{UInt8})
    n = Int(ntoh(reinterpret(UInt32, hdr[1:4])[1]))
    n == 0 && throw(ProtocolFramingError("framing violation: zero-length frame"))
    n > MAX_MESSAGE_BYTES && throw(ProtocolFramingError(
        "framing violation: declared length $n exceeds MAX_MESSAGE_BYTES ($MAX_MESSAGE_BYTES)"))
    return n
end

"""
    FrameDecoder()

Streaming frame decoder. Buffers partial data across `feed!` calls; handles
partial 4-byte headers, partial payloads, and several frames per feed.
Throws `ProtocolFramingError` on framing violations.
"""
mutable struct FrameDecoder
    buffer::Vector{UInt8}
    FrameDecoder() = new(UInt8[])
end

"""
    feed!(dec::FrameDecoder, bytes::AbstractVector{UInt8})::Vector{Vector{UInt8}}

Append `bytes` to the decoder buffer and return all frames now complete.
An empty feed (or insufficient data) returns an empty vector.
"""
function feed!(dec::FrameDecoder, bytes::AbstractVector{UInt8})::Vector{Vector{UInt8}}
    append!(dec.buffer, bytes)
    frames = Vector{UInt8}[]
    while length(dec.buffer) >= 4
        n = _frame_length_from_header(dec.buffer)
        length(dec.buffer) < 4 + n && break
        push!(frames, dec.buffer[5:(4 + n)])
        deleteat!(dec.buffer, 1:(4 + n))
    end
    return frames
end

"""
    build_request(command, request_id; protocol_version=1, episode_id=nothing, payload=Dict())

Build a request envelope Dict per the protocol spec. `episode_id = nothing`
serializes as JSON `null` (correct for RESET/CLOSE and for commands that
ignore it).
"""
function build_request(command::AbstractString, request_id::Integer;
                       protocol_version::Integer = PROTOCOL_VERSION,
                       episode_id = nothing,
                       payload = Dict{String,Any}())::Dict{String,Any}
    return Dict{String,Any}(
        "protocol_version" => Int(protocol_version),
        "request_id"       => Int(request_id),
        "command"          => String(command),
        "episode_id"       => episode_id,
        "payload"          => payload,
    )
end

"""
    validate_response(resp, request_id; protocol_version=1)

Validate a parsed response envelope against the request that produced it.
Returns the `result` object on success. Throws `GodotServerError` when
`ok == false` (with the server's `code`/`message`), and `GodotConnectionError`
when the envelope itself is structurally invalid (wrong protocol version,
mismatched/missing `request_id`, missing `ok`, malformed `error` object).
"""
function validate_response(resp, request_id::Integer;
                           protocol_version::Integer = PROTOCOL_VERSION)
    resp isa AbstractDict || throw(GodotConnectionError(
        "response is not a JSON object: $(repr(resp))"))
    version = get(resp, "protocol_version", nothing)
    version == protocol_version || throw(GodotConnectionError(
        "response protocol_version $(repr(version)) != $protocol_version"))
    rid = get(resp, "request_id", nothing)
    rid == request_id || throw(GodotConnectionError(
        "response request_id $(repr(rid)) does not match request $request_id"))
    ok = get(resp, "ok", nothing)
    ok isa Bool || throw(GodotConnectionError("response is missing the boolean \"ok\" flag"))
    if ok
        result = get(resp, "result", nothing)
        result isa AbstractDict || throw(GodotConnectionError(
            "ok response is missing the \"result\" object"))
        return result
    end
    err = get(resp, "error", nothing)
    if err isa AbstractDict && haskey(err, "code") && haskey(err, "message")
        throw(GodotServerError(string(err["code"]), string(err["message"]), Int(request_id)))
    end
    throw(GodotConnectionError("error response is missing a structured \"error\" object"))
end

"""
    read_exact(sock::TCPSocket, n::Integer, deadline::Real)::Vector{UInt8}

Read exactly `n` bytes from `sock`, blocking efficiently on socket I/O (no
busy polling). `deadline` is an absolute time in `time()` units; past it,
throws `GodotConnectionError("timeout …")`. Also throws `GodotConnectionError`
if the peer closes before `n` bytes arrive. Extra bytes beyond `n` stay
buffered on the socket. After a timeout the socket must be considered
unusable (the abandoned reader may consume later bytes).
"""
function read_exact(sock::TCPSocket, n::Integer, deadline::Real)::Vector{UInt8}
    # read(sock, n) blocks on the event loop until exactly n bytes or EOF;
    # run it in a task so we can enforce the deadline from here.
    ch = Channel{Any}(1)
    @async begin
        try
            put!(ch, read(sock, n))
        catch e
            try put!(ch, e) catch end
        end
    end
    if timedwait(() -> isready(ch), max(deadline - time(), 0.0); pollint = 0.001) == :timed_out
        throw(GodotConnectionError("timeout reading $n bytes from socket"))
    end
    result = take!(ch)
    result isa Exception && throw(GodotConnectionError(
        "connection closed by peer while reading $n bytes ($(sprint(showerror, result)))"))
    return result
end
