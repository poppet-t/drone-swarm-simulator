class_name MessageFramer
extends RefCounted

## Length-prefixed message framing for the RL TCP bridge (protocol v1).
##
## Every message on the wire is a 4-byte big-endian uint32 payload length
## followed by exactly that many payload bytes. One instance owns the
## reassembly buffer of ONE connection: TCP reads may split a frame anywhere
## or deliver several frames at once, so feed() buffers until complete
## payloads are available.
##
## Framing violations (declared length 0 or > MAX_MESSAGE_BYTES) are
## unrecoverable: `violated` latches true and the caller must close the
## connection. Complete frames extracted before the violation are still
## returned.

const MAX_MESSAGE_BYTES := 1048576

## Latched when a framing violation was seen; feed() is a no-op afterwards.
var violated := false

var _buffer := PackedByteArray()


## Builds one wire frame: 4-byte big-endian length prefix + payload.
## The header bytes are assembled manually so the encoding never depends on
## StreamPeer endianness settings.
static func encode_frame(payload: PackedByteArray) -> PackedByteArray:
	var n := payload.size()
	var out := PackedByteArray()
	out.resize(4 + n)
	out[0] = (n >> 24) & 0xFF
	out[1] = (n >> 16) & 0xFF
	out[2] = (n >> 8) & 0xFF
	out[3] = n & 0xFF
	for i in range(n):
		out[4 + i] = payload[i]
	return out


## Appends data to the reassembly buffer and returns an Array of the complete
## payload PackedByteArrays that are now available (possibly empty, possibly
## several). On a framing violation `violated` is set and the frames already
## extracted are returned.
func feed(data: PackedByteArray) -> Array:
	var frames: Array = []
	if violated:
		return frames
	_buffer.append_array(data)
	while true:
		if _buffer.size() < 4:
			break
		var n: int = (_buffer[0] << 24) | (_buffer[1] << 16) \
			| (_buffer[2] << 8) | _buffer[3]
		if n <= 0 or n > MAX_MESSAGE_BYTES:
			violated = true
			break
		if _buffer.size() < 4 + n:
			break
		frames.append(_buffer.slice(4, 4 + n))
		_buffer = _buffer.slice(4 + n)
	return frames


## Clears the reassembly buffer and the violation latch.
func reset() -> void:
	_buffer = PackedByteArray()
	violated = false
