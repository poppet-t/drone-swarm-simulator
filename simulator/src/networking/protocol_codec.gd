class_name ProtocolCodec
extends RefCounted

## Pure, socket-free envelope/JSON layer of the RL TCP bridge (protocol v1).
##
## decode_request() turns one framed payload into either a normalized request
## Dictionary or a ready-to-send error response envelope. Session state and
## command dispatch live in RLSession / RLServerCore, not here, so everything
## in this file is unit-testable without a SceneTree or sockets.
##
## Normalized request Dictionary:
##   protocol_version: int, request_id: int, command: Variant,
##   episode_id: int or null (integral numbers normalized to int),
##   payload: Variant (command handlers validate it).

const PROTOCOL_VERSION := 1


## Decodes one framed payload. Returns either
##   {"ok": true, "fatal": false, "request": {...normalized...}}
## or
##   {"ok": false, "fatal": bool, "response": <error envelope>}
## `fatal` is true only for invalid UTF-8: per the contract that is a framing
## violation, so the transport must close the connection without replying.
static func decode_request(payload: PackedByteArray) -> Dictionary:
	var text := payload.get_string_from_utf8()
	# get_string_from_utf8() lossily replaces invalid sequences instead of
	# reporting them, so validate by requiring an exact re-encode round-trip.
	if text.to_utf8_buffer() != payload:
		return _error(ProtocolError.MALFORMED_MESSAGE,
			"payload is not valid UTF-8", null, null, true)
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null or not (parsed is Dictionary):
		return _error(ProtocolError.MALFORMED_MESSAGE,
			"payload is not a JSON object", null, null)
	var raw: Dictionary = parsed

	# Godot parses every JSON number as float; integral floats are accepted
	# and normalized to int. Missing/non-numeric required fields are rejected
	# with request_id null (there is no valid ID to echo).
	var version_v: Variant = raw.get("protocol_version")
	if not is_integral_number(version_v):
		return _error(ProtocolError.MISSING_FIELD,
			"protocol_version must be an integer", null, null)
	var id_v: Variant = raw.get("request_id")
	if not is_integral_number(id_v) or int(id_v) < 0:
		return _error(ProtocolError.MISSING_FIELD,
			"request_id must be an integer >= 0", null, null)

	var request := {
		"protocol_version": int(version_v),
		"request_id": int(id_v),
		"command": raw.get("command"),
		"episode_id": raw.get("episode_id"),
		"payload": raw.get("payload"),
	}
	if is_integral_number(request["episode_id"]):
		request["episode_id"] = int(request["episode_id"])

	if int(version_v) != PROTOCOL_VERSION:
		return _error(ProtocolError.PROTOCOL_VERSION_MISMATCH,
			"protocol_version must be %d" % PROTOCOL_VERSION,
			request["request_id"], request["episode_id"])
	return {"ok": true, "fatal": false, "request": request}


## Builds a success response envelope around a command result.
static func build_result(request_id: Variant, episode_id: Variant,
		result: Dictionary) -> Dictionary:
	return {
		"protocol_version": PROTOCOL_VERSION,
		"request_id": request_id,
		"ok": true,
		"episode_id": episode_id,
		"result": result,
		"error": null,
	}


## True for JSON numbers with an integral value (TYPE_INT, or a finite
## TYPE_FLOAT with no fraction). Booleans, strings and null are rejected.
static func is_integral_number(v: Variant) -> bool:
	if typeof(v) == TYPE_INT:
		return true
	if typeof(v) == TYPE_FLOAT:
		var f: float = v
		return is_finite(f) and f == floor(f)
	return false


static func _error(code: String, message: String, request_id: Variant,
		episode_id: Variant, fatal := false) -> Dictionary:
	return {
		"ok": false,
		"fatal": fatal,
		"response": ProtocolError.make(code, message, request_id, episode_id),
	}
