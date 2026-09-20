extends TestCase

## Network protocol tests (protocol v1): framing, envelope codec, session
## state machine, episode lifecycle, determinism, and one real loopback
## socket round trip. Socket-free tests drive ProtocolCodec + RLSession +
## RLServerCore directly; the socket test pumps RLServerCore.poll() by hand.

var tree: SceneTree

var _socket_framer := MessageFramer.new()
var _socket_responses: Array = []


# ---------------------------------------------------------------- helpers


func _make_session(core: RLServerCore) -> RLSession:
	return RLSession.new(core)


func _hello_payload() -> Dictionary:
	return {"client_name": "test_network", "client_version": "0.0.0",
		"supported_protocol_versions": [1]}


func _request(command: String, request_id: int, payload: Variant = null,
		episode_id: Variant = null) -> Dictionary:
	return {"protocol_version": 1, "request_id": request_id, "command": command,
		"episode_id": episode_id, "payload": payload}


## Full pipeline: JSON text -> decode -> session.handle -> response envelope.
func _send(session: RLSession, request: Dictionary) -> Dictionary:
	return _send_text(session, JSON.stringify(request))


func _send_text(session: RLSession, text: String) -> Dictionary:
	var decoded: Dictionary = ProtocolCodec.decode_request(text.to_utf8_buffer())
	if not decoded["ok"]:
		return decoded["response"]
	return session.handle(decoded["request"])


func _do_hello(session: RLSession, request_id: int = 1) -> Dictionary:
	return _send(session, _request("HELLO", request_id, _hello_payload()))


func _reset_ok(session: RLSession, seed: int, agents: int,
		request_id: int = 2) -> Dictionary:
	var response := _send(session, _request("RESET", request_id,
		{"seed": seed, "agent_count": agents}))
	check_eq(response["ok"], true, "RESET(%d agents) ok" % agents)
	return response


func _check_error(response: Dictionary, code: String, request_id: Variant,
		msg: String) -> void:
	check_eq(response["ok"], false, msg + ": not ok")
	check_eq(response["error"]["code"], code, msg + ": error code")
	check_eq(response["request_id"], request_id, msg + ": request_id echo")


func _write_message(peer: StreamPeerTCP, request: Dictionary) -> void:
	peer.put_data(MessageFramer.encode_frame(
		JSON.stringify(request).to_utf8_buffer()))


## Pumps server and client until one framed response arrives (bounded).
## Responses that arrived in the same TCP read are queued, never dropped.
func _read_response(peer: StreamPeerTCP, core: RLServerCore,
		max_iters: int) -> Dictionary:
	if not _socket_responses.is_empty():
		var queued: Dictionary = _socket_responses.pop_front()
		return queued
	for _i in range(max_iters):
		core.poll()
		peer.poll()
		var available := peer.get_available_bytes()
		if available > 0:
			var res: Array = peer.get_partial_data(available)
			if res[0] == OK:
				var chunk: PackedByteArray = res[1]
				var frames: Array = _socket_framer.feed(chunk)
				for frame in frames:
					var frame_bytes: PackedByteArray = frame
					var parsed: Variant = JSON.parse_string(
						frame_bytes.get_string_from_utf8())
					if parsed is Dictionary:
						_socket_responses.append(parsed)
					else:
						_socket_responses.append({})
				if not _socket_responses.is_empty():
					var first: Dictionary = _socket_responses.pop_front()
					return first
		OS.delay_msec(1)
	push_error("test_network: timed out waiting for a server response")
	return {}


# ---------------------------------------------------------------- framing


func test_frame_encode_big_endian() -> void:
	var payload := PackedByteArray()
	payload.resize(258)
	var frame := MessageFramer.encode_frame(payload)
	check_eq(frame.size(), 4 + 258, "frame size is header + payload")
	check_eq(frame[0], 0x00, "length byte 0 (MSB)")
	check_eq(frame[1], 0x00, "length byte 1")
	check_eq(frame[2], 0x01, "length byte 2")
	check_eq(frame[3], 0x02, "length byte 3 (LSB)")


func test_frame_round_trip() -> void:
	var payload := "hello julia".to_utf8_buffer()
	var framer := MessageFramer.new()
	var frames: Array = framer.feed(MessageFramer.encode_frame(payload))
	check_eq(frames.size(), 1, "one complete frame")
	check_eq(frames[0], payload, "payload survives the round trip")
	check(not framer.violated, "no violation")


func test_frame_fragmented_header() -> void:
	var payload := "fragmented".to_utf8_buffer()
	var frame := MessageFramer.encode_frame(payload)
	var framer := MessageFramer.new()
	check_eq(framer.feed(frame.slice(0, 1)).size(), 0, "1 header byte: no frame")
	check_eq(framer.feed(frame.slice(1, 3)).size(), 0, "3 header bytes: no frame")
	var frames: Array = framer.feed(frame.slice(3))
	check_eq(frames.size(), 1, "completes once the rest arrives")
	check_eq(frames[0], payload, "payload intact")


func test_frame_fragmented_payload() -> void:
	var payload := PackedByteArray()
	for i in range(100):
		payload.append(i)
	var frame := MessageFramer.encode_frame(payload)
	var framer := MessageFramer.new()
	check_eq(framer.feed(frame.slice(0, 44)).size(), 0, "partial payload: no frame")
	var frames: Array = framer.feed(frame.slice(44))
	check_eq(frames.size(), 1, "completes")
	check_eq(frames[0], payload, "payload intact")


func test_frame_multiple_in_one_feed() -> void:
	var a := "one".to_utf8_buffer()
	var b := "two".to_utf8_buffer()
	var c := "three".to_utf8_buffer()
	var blob := MessageFramer.encode_frame(a)
	blob.append_array(MessageFramer.encode_frame(b))
	blob.append_array(MessageFramer.encode_frame(c))
	var framer := MessageFramer.new()
	var frames: Array = framer.feed(blob)
	check_eq(frames.size(), 3, "three frames from one feed")
	check_eq(frames[0], a, "frame 1")
	check_eq(frames[1], b, "frame 2")
	check_eq(frames[2], c, "frame 3")


func test_frame_oversized_violation() -> void:
	var good := "ok".to_utf8_buffer()
	var blob := MessageFramer.encode_frame(good)
	# Hand-build a header declaring MAX_MESSAGE_BYTES + 1.
	var n := MessageFramer.MAX_MESSAGE_BYTES + 1
	blob.append((n >> 24) & 0xFF)
	blob.append((n >> 16) & 0xFF)
	blob.append((n >> 8) & 0xFF)
	blob.append(n & 0xFF)
	var framer := MessageFramer.new()
	var frames: Array = framer.feed(blob)
	check_eq(frames.size(), 1, "frame completed before the violation is returned")
	check_eq(frames[0], good, "good frame intact")
	check(framer.violated, "oversized length latches the violation")
	check_eq(framer.feed(good).size(), 0, "feed is a no-op once violated")
	framer.reset()
	check(not framer.violated, "reset clears the violation")


func test_frame_zero_length_violation() -> void:
	var framer := MessageFramer.new()
	var frames: Array = framer.feed(PackedByteArray([0, 0, 0, 0]))
	check_eq(frames.size(), 0, "no frames")
	check(framer.violated, "zero length latches the violation")


# ---------------------------------------------------------------- codec


func test_decode_invalid_utf8() -> void:
	# 0xFF/0xFE are never valid UTF-8.
	var decoded: Dictionary = ProtocolCodec.decode_request(
		PackedByteArray([0x7B, 0xFF, 0xFE, 0x7D]))
	check_eq(decoded["ok"], false, "invalid UTF-8 rejected")
	check_eq(decoded["response"]["error"]["code"],
		ProtocolError.MALFORMED_MESSAGE, "error code")
	check_eq(decoded["response"]["request_id"], null, "request_id null")
	check_eq(decoded["fatal"], true, "invalid UTF-8 is fatal (close, no reply)")


func test_decode_malformed_json() -> void:
	var decoded: Dictionary = ProtocolCodec.decode_request(
		"{not json".to_utf8_buffer())
	check_eq(decoded["ok"], false, "malformed JSON rejected")
	check_eq(decoded["response"]["error"]["code"],
		ProtocolError.MALFORMED_MESSAGE, "error code")
	check_eq(decoded["response"]["request_id"], null, "request_id null")
	check_eq(decoded["fatal"], false, "malformed JSON keeps the connection open")
	# A bare NaN token is not valid JSON and lands here, never in
	# INVALID_ACTION_VALUE.
	var nan_decoded: Dictionary = ProtocolCodec.decode_request(
		("{\"protocol_version\": 1, \"request_id\": 1, \"command\": \"STEP\","
			+ " \"payload\": NaN}").to_utf8_buffer())
	check_eq(nan_decoded["response"]["error"]["code"],
		ProtocolError.MALFORMED_MESSAGE, "bare NaN token is malformed JSON")


func test_decode_non_object() -> void:
	for text in ["[1, 2, 3]", "42", "\"hello\"", "null", "true"]:
		var decoded: Dictionary = ProtocolCodec.decode_request(
			text.to_utf8_buffer())
		check_eq(decoded["ok"], false, "non-object rejected: " + text)
		check_eq(decoded["response"]["error"]["code"],
			ProtocolError.MALFORMED_MESSAGE, "error code for: " + text)
		check_eq(decoded["response"]["request_id"], null,
			"request_id null for: " + text)


func test_decode_missing_request_id() -> void:
	var decoded: Dictionary = ProtocolCodec.decode_request(JSON.stringify(
		{"protocol_version": 1, "command": "PING"}).to_utf8_buffer())
	check_eq(decoded["ok"], false, "missing request_id rejected")
	check_eq(decoded["response"]["error"]["code"],
		ProtocolError.MISSING_FIELD, "error code")
	check_eq(decoded["response"]["request_id"], null, "request_id null")
	var bad: Dictionary = ProtocolCodec.decode_request(JSON.stringify(
		{"protocol_version": 1, "request_id": "abc", "command": "PING"}
		).to_utf8_buffer())
	check_eq(bad["response"]["error"]["code"], ProtocolError.MISSING_FIELD,
		"string request_id rejected")
	check_eq(bad["response"]["request_id"], null, "request_id still null")


func test_decode_normalizes_numbers() -> void:
	# Godot parses every JSON number as float; integral values normalize.
	var decoded: Dictionary = ProtocolCodec.decode_request(
		("{\"protocol_version\": 1.0, \"request_id\": 7.0,"
			+ " \"command\": \"PING\", \"episode_id\": 3.0}").to_utf8_buffer())
	if check(decoded["ok"], "integral floats accepted"):
		var request: Dictionary = decoded["request"]
		check_eq(typeof(request["request_id"]), TYPE_INT,
			"request_id normalized to int")
		check_eq(request["request_id"], 7, "request_id value")
		check_eq(typeof(request["episode_id"]), TYPE_INT,
			"episode_id normalized to int")
		check_eq(request["episode_id"], 3, "episode_id value")


func test_invalid_protocol_version() -> void:
	var decoded: Dictionary = ProtocolCodec.decode_request(JSON.stringify(
		{"protocol_version": 2, "request_id": 9, "command": "PING"}
		).to_utf8_buffer())
	check_eq(decoded["ok"], false, "protocol_version 2 rejected")
	check_eq(decoded["response"]["error"]["code"],
		ProtocolError.PROTOCOL_VERSION_MISMATCH, "error code")
	check_eq(decoded["response"]["request_id"], 9, "valid request_id echoed")


# ---------------------------------------------------------------- session


func test_command_before_hello() -> void:
	var session := _make_session(RLServerCore.new())
	var response := _send(session, _request("PING", 5))
	_check_error(response, ProtocolError.EXPECTED_HELLO, 5, "PING before HELLO")


func test_hello_wrong_versions() -> void:
	var session := _make_session(RLServerCore.new())
	var response := _send(session, _request("HELLO", 1,
		{"supported_protocol_versions": [2, 3]}))
	_check_error(response, ProtocolError.PROTOCOL_VERSION_MISMATCH, 1,
		"no common protocol version")
	check(not session.hello_done, "hello_done stays false after a failed HELLO")


func test_hello_result() -> void:
	var session := _make_session(RLServerCore.new())
	var response := _do_hello(session)
	check_eq(response["ok"], true, "HELLO ok")
	var result: Dictionary = response["result"]
	check_eq(result["server_name"], "GDST-RL-Simulator", "server name")
	check_eq(result["protocol_version"], 1, "protocol version")
	check(result["capabilities"] is Array, "capabilities list present")
	check(String(result["godot_version"]).begins_with("4."),
		"godot version string")
	check(session.hello_done, "hello_done set")


func test_unknown_command() -> void:
	var session := _make_session(RLServerCore.new())
	_do_hello(session)
	var response := _send(session, _request("TELEPORT", 8))
	_check_error(response, ProtocolError.UNKNOWN_COMMAND, 8, "unknown command")


func test_duplicate_request_id() -> void:
	# The server does not enforce uniqueness: both are processed and both
	# responses echo the ID they carried.
	var session := _make_session(RLServerCore.new())
	_do_hello(session)
	var first := _send(session, _request("PING", 42))
	var second := _send(session, _request("PING", 42))
	check_eq(first["ok"], true, "first duplicate processed")
	check_eq(second["ok"], true, "second duplicate processed")
	check_eq(first["request_id"], 42, "first echoes the id")
	check_eq(second["request_id"], 42, "second echoes the id")


func test_ping() -> void:
	var session := _make_session(RLServerCore.new())
	_do_hello(session)
	var response := _send(session, _request("PING", 3))
	check_eq(response["ok"], true, "PING ok")
	var result: Dictionary = response["result"]
	check_eq(result["pong"], true, "pong")
	check(result.has("server_time_msec"), "server_time_msec present")
	check_eq(result["episode_id"], null, "no episode before RESET")
	_reset_ok(session, 7, 1)
	var after := _send(session, _request("PING", 5))
	check_eq(after["result"]["episode_id"], 1, "current episode reported")


func test_close() -> void:
	var session := _make_session(RLServerCore.new())
	_do_hello(session)
	var response := _send(session, _request("CLOSE", 6))
	check_eq(response["ok"], true, "CLOSE ok")
	check_eq(response["result"]["closing"], true, "closing flag")
	check(session.close_requested, "close_requested set")


# ---------------------------------------------------------------- RESET


func test_reset_bad_seed() -> void:
	var session := _make_session(RLServerCore.new())
	_do_hello(session)
	_check_error(_send(session, _request("RESET", 1, {"seed": -1})),
		ProtocolError.INVALID_SEED, 1, "seed -1")
	_check_error(_send(session, _request("RESET", 2, {"seed": 1.5})),
		ProtocolError.INVALID_SEED, 2, "seed 1.5")
	_check_error(_send(session, _request("RESET", 3, {"seed": "x"})),
		ProtocolError.INVALID_SEED, 3, "seed string")
	_check_error(_send(session, _request("RESET", 4, {"agent_count": 1})),
		ProtocolError.INVALID_SEED, 4, "seed missing")
	_check_error(_send(session, _request("RESET", 5, {"seed": true})),
		ProtocolError.INVALID_SEED, 5, "seed boolean")
	_check_error(_send_text(session,
		"{\"protocol_version\": 1, \"request_id\": 6, \"command\": \"RESET\","
			+ " \"payload\": {\"seed\": 1e20}}"),
		ProtocolError.INVALID_SEED, 6, "seed beyond 2^63 - 1")


func test_reset_bad_agent_count() -> void:
	var session := _make_session(RLServerCore.new())
	_do_hello(session)
	_check_error(_send(session, _request("RESET", 1, {"seed": 1, "agent_count": 0})),
		ProtocolError.INVALID_AGENT_COUNT, 1, "agent_count 0")
	_check_error(_send(session, _request("RESET", 2, {"seed": 1, "agent_count": 17})),
		ProtocolError.INVALID_AGENT_COUNT, 2, "agent_count 17")
	_check_error(_send(session, _request("RESET", 3, {"seed": 1, "agent_count": 2.5})),
		ProtocolError.INVALID_AGENT_COUNT, 3, "agent_count 2.5")


func test_reset_unknown_scenario() -> void:
	var session := _make_session(RLServerCore.new())
	_do_hello(session)
	_check_error(_send(session, _request("RESET", 1, {"seed": 1, "scenario": "moon"})),
		ProtocolError.UNKNOWN_SCENARIO, 1, "unknown scenario")


# ---------------------------------------------------------------- STEP


func test_step_before_reset() -> void:
	var session := _make_session(RLServerCore.new())
	_do_hello(session)
	var response := _send(session, _request("STEP", 1,
		{"actions": [[0.0, 0.0, 0.0, 0.0]]}, 1))
	_check_error(response, ProtocolError.NO_ACTIVE_EPISODE, 1,
		"STEP before RESET")


func test_step_bad_action_shape() -> void:
	var session := _make_session(RLServerCore.new())
	_do_hello(session)
	_reset_ok(session, 7, 2)
	var wrong_outer := _send(session, _request("STEP", 3,
		{"actions": [[0.0, 0.0, 0.0, 0.0]]}, 1))
	_check_error(wrong_outer, ProtocolError.INVALID_ACTION_SHAPE, 3,
		"outer count 1 != 2")
	check(String(wrong_outer["error"]["message"]).contains(
		"Expected 2 actions for 2 active agents."), "message carries the counts")
	var wrong_inner := _send(session, _request("STEP", 4,
		{"actions": [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 0.0]]}, 1))
	_check_error(wrong_inner, ProtocolError.INVALID_ACTION_SHAPE, 4,
		"inner width 3 != 4")
	var missing := _send(session, _request("STEP", 5, {}, 1))
	_check_error(missing, ProtocolError.INVALID_ACTION_SHAPE, 5,
		"actions field missing")


func test_step_bad_action_value() -> void:
	var session := _make_session(RLServerCore.new())
	_do_hello(session)
	_reset_ok(session, 7, 1)
	var stringy := _send(session, _request("STEP", 3,
		{"actions": [["fast", 0.0, 0.0, 0.0]]}, 1))
	_check_error(stringy, ProtocolError.INVALID_ACTION_VALUE, 3,
		"string component")
	# 1e999 overflows to +INF at JSON parse time: a non-finite action value.
	var huge := _send_text(session,
		"{\"protocol_version\": 1, \"request_id\": 4, \"command\": \"STEP\","
			+ " \"episode_id\": 1, \"payload\": {\"actions\": [[1e999, 0, 0, 0]]}}")
	_check_error(huge, ProtocolError.INVALID_ACTION_VALUE, 4,
		"1e999 component is non-finite")


func test_step_stale_episode() -> void:
	var core := RLServerCore.new()
	var session := _make_session(core)
	_do_hello(session)
	_reset_ok(session, 7, 1, 2)
	_reset_ok(session, 8, 1, 3) # replaces episode 1 with episode 2
	check_eq(core.current_episode_id, 2, "second RESET episode is current")
	var response := _send(session, _request("STEP", 4,
		{"actions": [[0.0, 0.0, 0.0, 0.0]]}, 1))
	_check_error(response, ProtocolError.STALE_EPISODE, 4, "old episode id")


func test_step_after_episode_end() -> void:
	var session := _make_session(RLServerCore.new())
	_do_hello(session)
	_reset_ok(session, 5, 1)
	# Zero actions can never reach the waypoint: truncates at max_steps.
	var last := {}
	for i in range(500):
		last = _send(session, _request("STEP", 100 + i,
			{"actions": [[0.0, 0.0, 0.0, 0.0]]}, 1))
	check_eq(last["ok"], true, "final step ok")
	check_eq(last["result"]["truncated"], true, "episode truncated at max_steps")
	var response := _send(session, _request("STEP", 999,
		{"actions": [[0.0, 0.0, 0.0, 0.0]]}, 1))
	_check_error(response, ProtocolError.EPISODE_ENDED, 999,
		"step after truncation")


# ---------------------------------------------------------------- results


func test_get_spec() -> void:
	var session := _make_session(RLServerCore.new())
	_do_hello(session)
	var response := _send(session, _request("GET_SPEC", 2))
	check_eq(response["ok"], true, "GET_SPEC ok")
	var result: Dictionary = response["result"]
	check_eq(result["physics_hz"], 60, "physics_hz from SimConfig")
	check_eq(result["policy_hz"], 20, "policy_hz from SimConfig")
	check_eq(result["substeps"], 3, "substeps from SimConfig")
	check_eq(result["action"]["shape_per_agent"], [4], "action shape")
	check_eq(result["observation"]["shape_per_agent"],
		[WaypointScenario.OBS_SIZE], "observation shape")
	check_eq(result["action"]["names"],
		["accel_x", "accel_y", "accel_z", "yaw_rate"], "action names")
	check_eq(result["minimum_agents"], 1, "minimum agents")
	check_eq(result["maximum_agents"], RLServerCore.MAX_AGENTS, "maximum agents")
	check_eq(result["supports_variable_agents"], true, "variable agents")
	check_eq(result["scenarios"], ["waypoint"], "scenarios from the registry")


func test_reset_step_result_shapes() -> void:
	var session := _make_session(RLServerCore.new())
	_do_hello(session)
	var reset_response := _reset_ok(session, 1234, 4)
	check_eq(reset_response["episode_id"], 1, "envelope episode id")
	var reset_result: Dictionary = reset_response["result"]
	check_eq(reset_result["episode_id"], 1, "first episode id is 1")
	var observations: Array = reset_result["observations"]
	check_eq(observations.size(), 4, "one observation per agent")
	var obs_ok := true
	for o in observations:
		if not (o is Array) or o.size() != WaypointScenario.OBS_SIZE:
			obs_ok = false
	check(obs_ok, "each observation is a 23-float array")
	check_eq(reset_result["active_mask"], [1, 1, 1, 1], "all active after reset")
	check_eq(reset_result["info"]["seed"], 1234, "info seed")
	check_eq(reset_result["info"]["steps"], 0, "info steps 0")

	var step_response := _send(session, _request("STEP", 10, {
		"actions": [[0.1, 0.0, 0.0, 0.0], [0.0, 0.1, 0.0, 0.0],
			[0.0, 0.0, 0.1, 0.0], [0.0, 0.0, 0.0, 0.1]]}, 1))
	check_eq(step_response["ok"], true, "STEP ok")
	var result: Dictionary = step_response["result"]
	check_eq(result["observations"].size(), 4, "4 observations after the step")
	var rewards: Array = result["rewards"]
	check_eq(rewards.size(), 4, "one reward per agent")
	var reward_sum := 0.0
	for r in rewards:
		reward_sum += r
	check_approx(result["team_reward"], reward_sum, 1e-5,
		"team_reward is the sum of rewards")
	check_eq(result["active_mask"], [1, 1, 1, 1], "active mask after the step")
	check_eq(result["terminated"], false, "not terminated")
	check_eq(result["truncated"], false, "not truncated")
	var info: Dictionary = result["info"]
	check_eq(info["steps"], 1, "one step counted")
	check_eq(info["seed"], 1234, "info seed")
	check_eq(String(info["state_hash"]).length(), 64,
		"state_hash is 64 hex chars")
	check(int(info["step_time_usec"]) >= 0, "step_time_usec >= 0")


func test_determinism_over_session() -> void:
	# Two independent cores given RESET(seed=42) and the identical action
	# sequence must produce identical state hashes at every step.
	var session_a := _make_session(RLServerCore.new())
	var session_b := _make_session(RLServerCore.new())
	_do_hello(session_a)
	_do_hello(session_b)
	_reset_ok(session_a, 42, 2)
	_reset_ok(session_b, 42, 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var hashes_a: Array = []
	var hashes_b: Array = []
	for i in range(50):
		var actions: Array = []
		for _j in range(2):
			actions.append([rng.randf_range(-1.0, 1.0),
				rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0),
				rng.randf_range(-1.0, 1.0)])
		var text := JSON.stringify(_request("STEP", 100 + i,
			{"actions": actions}, 1))
		var response_a := _send_text(session_a, text)
		var response_b := _send_text(session_b, text)
		var ok_a := check_eq(response_a["ok"], true, "step %d ok (A)" % i)
		var ok_b := check_eq(response_b["ok"], true, "step %d ok (B)" % i)
		if not (ok_a and ok_b):
			break
		hashes_a.append(response_a["result"]["info"]["state_hash"])
		hashes_b.append(response_b["result"]["info"]["state_hash"])
	check_eq(hashes_a, hashes_b,
		"identical action sequences produce identical state hashes")


# ---------------------------------------------------------------- socket


func test_socket_loopback() -> void:
	var core := RLServerCore.new()
	core.host = "127.0.0.1"
	var started := false
	for candidate_port in [19765, 19766, 19767, 19768, 19769]:
		core.port = candidate_port
		if core.start():
			started = true
			break
	if not check(started, "server starts on a test port"):
		return
	var peer := StreamPeerTCP.new()
	if not check_eq(peer.connect_to_host("127.0.0.1", core.port), OK,
		"connect_to_host"):
		core.stop()
		return
	var connected := false
	for _i in range(4000):
		core.poll()
		peer.poll()
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			connected = true
			break
		OS.delay_msec(1)
	if not check(connected, "loopback connection established"):
		core.stop()
		return

	# HELLO dribbled in one byte at a time: server-side reassembly.
	var hello_frame := MessageFramer.encode_frame(JSON.stringify(
		_request("HELLO", 1, _hello_payload())).to_utf8_buffer())
	for i in range(hello_frame.size()):
		peer.put_data(hello_frame.slice(i, i + 1))
		core.poll()
	var hello_response := _read_response(peer, core, 4000)
	check_eq(hello_response.get("ok"), true,
		"HELLO over the socket (1-byte fragments)")
	check_eq(hello_response.get("result", {}).get("server_name"),
		"GDST-RL-Simulator", "server name over the socket")

	# RESET + STEP over the socket.
	_write_message(peer, _request("RESET", 2, {"seed": 1234, "agent_count": 2}))
	var reset_response := _read_response(peer, core, 4000)
	check_eq(reset_response.get("ok"), true, "RESET over the socket")
	check_eq(reset_response.get("result", {}).get("episode_id"), 1.0,
		"episode id 1 over the socket")
	_write_message(peer, _request("STEP", 3,
		{"actions": [[0, 0, 0, 0], [0, 0, 0, 0]]}, 1))
	var step_response := _read_response(peer, core, 4000)
	check_eq(step_response.get("ok"), true, "STEP over the socket")
	check_eq(step_response.get("result", {}).get("rewards", []).size(), 2,
		"2 rewards over the socket")

	# Two frames concatenated in one send.
	var two_pings := MessageFramer.encode_frame(
		JSON.stringify(_request("PING", 40)).to_utf8_buffer())
	two_pings.append_array(MessageFramer.encode_frame(
		JSON.stringify(_request("PING", 41)).to_utf8_buffer()))
	peer.put_data(two_pings)
	var pong_a := _read_response(peer, core, 4000)
	var pong_b := _read_response(peer, core, 4000)
	check_eq(pong_a.get("request_id"), 40.0, "first concatenated frame answered")
	check_eq(pong_b.get("request_id"), 41.0, "second concatenated frame answered")

	# CLOSE: server answers, then closes the connection.
	_write_message(peer, _request("CLOSE", 50))
	var close_response := _read_response(peer, core, 4000)
	check_eq(close_response.get("result", {}).get("closing"), true,
		"CLOSE over the socket")
	var closed := false
	for _i in range(4000):
		core.poll()
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			closed = true
			break
		OS.delay_msec(1)
	check(closed, "server closes the connection after CLOSE")
	core.stop()
