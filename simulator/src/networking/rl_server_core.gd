class_name RLServerCore
extends RefCounted

## Transport + episode ownership of the RL TCP bridge (protocol v1).
##
## A RefCounted on purpose: tests can instantiate it without a SceneTree and
## drive poll() manually. The CLI wrapper (rl_server.gd) only parses args,
## calls start() and pumps poll().
##
## Episode state lives HERE, shared by all sessions: `env` is the live
## episode (null when none), `current_episode_id` its server-assigned ID.
## IDs increase monotonically from 1 for the lifetime of the process via
## `_episode_seq`, which is never reset; on owner disconnect the episode is
## abandoned (env cleared), so a later STEP naming its ID gets STALE_EPISODE.

const MAX_AGENTS := 16
const MAX_SEED := 9223372036854775807 # 2^63 - 1

var host := "127.0.0.1"
var port := 9100
var max_clients := 1

## Live episode context; null before the first RESET and after an abandon.
var env: SwarmEnv = null
## ID of the live episode (0 = none). Server-assigned, see `_episode_seq`.
var current_episode_id := 0
## True once the live episode terminated or truncated; STEP then fails with
## EPISODE_ENDED until the next RESET.
var episode_ended := false
## Connection id owning the live episode (-1 = none).
var episode_owner := -1

var _episode_seq := 0
var _server: TCPServer = null
var _clients: Array[Client] = []
var _next_client_id := 1


## One accepted connection: socket, reassembly buffer and session state.
class Client:
	extends RefCounted
	var id: int
	var peer: StreamPeerTCP
	var framer := MessageFramer.new()
	var session: RLSession

	func _init(p_id: int, p_peer: StreamPeerTCP, core: RLServerCore) -> void:
		id = p_id
		peer = p_peer
		session = RLSession.new(core)
		session.connection_id = p_id


## Starts listening. On failure logs and returns false.
func start() -> bool:
	_server = TCPServer.new()
	var err := _server.listen(port, host)
	if err != OK:
		push_error("rl_server: listen %s:%d failed (error %d)" % [host, port, err])
		_server = null
		return false
	print("rl_server: listening on %s:%d (max_clients=%d)" % [host, port, max_clients])
	return true


## Accepts pending connections and services every live client once. Call
## repeatedly (once per main-loop iteration, or per test pump).
func poll() -> void:
	if _server == null:
		return
	_accept_pending()
	var dead: Array[Client] = []
	for client in _clients:
		if not _service_client(client):
			dead.append(client)
	for client in dead:
		_remove_client(client)


## Closes all clients and the listening socket.
func stop() -> void:
	for client in _clients:
		client.peer.disconnect_from_host()
	_clients.clear()
	if _server != null:
		_server.stop()
		_server = null


# ---------------------------------------------------------------- commands


## HELLO: negotiates the protocol version and opens the session.
func handle_hello(session: RLSession, request: Dictionary) -> Dictionary:
	var request_id: Variant = request.get("request_id")
	var payload: Variant = _payload_object(request)
	var supported := false
	if payload != null:
		var versions_v: Variant = payload.get("supported_protocol_versions")
		if versions_v is Array:
			for v in versions_v:
				if ProtocolCodec.is_integral_number(v) \
						and int(v) == ProtocolCodec.PROTOCOL_VERSION:
					supported = true
					break
	if not supported:
		return ProtocolError.make(ProtocolError.PROTOCOL_VERSION_MISMATCH,
			"no common protocol version (server speaks %d)" \
				% ProtocolCodec.PROTOCOL_VERSION,
			request_id, request.get("episode_id"))
	var client_name := str(payload.get("client_name", "<unnamed>"))
	var client_version := str(payload.get("client_version", "<unknown>"))
	print("rl_server: hello client=%s version=%s" % [client_name, client_version])
	session.hello_done = true
	var result := {
		"server_name": "GDST-RL-Simulator",
		"godot_version": str(Engine.get_version_info().get("string", "")),
		"protocol_version": ProtocolCodec.PROTOCOL_VERSION,
		"capabilities": ["get_spec", "reset", "step", "batched_agents",
			"deterministic_seed", "observation_v2"],
	}
	return ProtocolCodec.build_result(request_id, request.get("episode_id"), result)


## GET_SPEC: observation/action space description, derived from SimConfig and
## a probe scenario instance, not duplicated constants.
func handle_get_spec(request: Dictionary) -> Dictionary:
	var request_id: Variant = request.get("request_id")
	var config := SimConfig.new()
	var names: Array[String] = Scenario.available()
	var probe := SwarmEnv.new()
	if names.is_empty() or not probe.configure(config) \
			or not probe.reset(0, names[0], 1):
		return ProtocolError.make(ProtocolError.INTERNAL_ERROR,
			"could not build spec probe: " + probe.last_error,
			request_id, request.get("episode_id"))
	var spec := probe.get_spec()
	var scenarios: Array = []
	scenarios.append_array(names)
	var result := {
		"action": {
			"shape_per_agent": [spec["action_size"]],
			"dtype": "float32",
			"minimum": spec["action_low"],
			"maximum": spec["action_high"],
			"names": ["accel_x", "accel_y", "accel_z", "yaw_rate"],
		},
		# Default observation stays v1 for backward compatibility; clients opt
		# into newer contracts per episode via RESET.observation_version.
		"observation": {
			"shape_per_agent": [spec["obs_size"]],
			"dtype": "float32",
		},
		"observation_versions": [1, ObservationV2.VERSION],
		"observation_version_default": 1,
		"observation_layouts": {
			str(ObservationV2.VERSION): ObservationV2.layout(),
		},
		"supports_variable_agents": true,
		"minimum_agents": 1,
		"maximum_agents": MAX_AGENTS,
		"scenarios": scenarios,
		"physics_hz": roundi(1.0 / config.physics_dt),
		"policy_hz": roundi(1.0 / config.policy_dt),
		"substeps": config.physics_substeps,
	}
	return ProtocolCodec.build_result(request_id, request.get("episode_id"), result)


## RESET: validates the payload, creates a fresh SwarmEnv episode and assigns
## the next server episode ID.
func handle_reset(session: RLSession, request: Dictionary) -> Dictionary:
	var request_id: Variant = request.get("request_id")
	var payload: Variant = _payload_object(request)
	if payload == null:
		return ProtocolError.make(ProtocolError.MISSING_FIELD,
			"payload must be an object", request_id, request.get("episode_id"))

	var seed_v: Variant = payload.get("seed")
	if not ProtocolCodec.is_integral_number(seed_v):
		return ProtocolError.make(ProtocolError.INVALID_SEED,
			"seed is required and must be an integer", request_id, null)
	var seed_f := float(seed_v)
	if seed_f < 0.0 or seed_f >= 9223372036854775808.0: # 2^63
		return ProtocolError.make(ProtocolError.INVALID_SEED,
			"seed must be in [0, %d]" % MAX_SEED, request_id, null)
	var seed := int(seed_f)

	var scenario_name := "waypoint"
	var scenario_v: Variant = payload.get("scenario")
	if scenario_v != null:
		if not (scenario_v is String) \
				or not Scenario.available().has(scenario_v):
			return ProtocolError.make(ProtocolError.UNKNOWN_SCENARIO,
				"unknown scenario '%s'" % str(scenario_v), request_id, null)
		scenario_name = scenario_v

	var agent_count := 1
	var agents_v: Variant = payload.get("agent_count")
	if agents_v != null:
		if not ProtocolCodec.is_integral_number(agents_v):
			return ProtocolError.make(ProtocolError.INVALID_AGENT_COUNT,
				"agent_count must be an integer", request_id, null)
		agent_count = int(agents_v)
		if agent_count < 1 or agent_count > MAX_AGENTS:
			return ProtocolError.make(ProtocolError.INVALID_AGENT_COUNT,
				"agent_count must be in [1, %d]" % MAX_AGENTS, request_id, null)

	# Optional observation-contract selection; defaults to v1.
	var observation_version := 1
	var obs_version_v: Variant = payload.get("observation_version")
	if obs_version_v != null:
		if not ProtocolCodec.is_integral_number(obs_version_v):
			return ProtocolError.make(
				ProtocolError.OBSERVATION_VERSION_UNSUPPORTED,
				"observation_version must be an integer", request_id, null)
		observation_version = int(obs_version_v)
		if observation_version != 1 and observation_version != ObservationV2.VERSION:
			return ProtocolError.make(
				ProtocolError.OBSERVATION_VERSION_UNSUPPORTED,
				"unsupported observation_version %d (supported: 1, %d)" %
					[observation_version, ObservationV2.VERSION],
				request_id, null)
	# options: reserved, currently ignored.

	var new_env := SwarmEnv.new()
	if not new_env.configure(SimConfig.new()) \
			or not new_env.reset(seed, scenario_name, agent_count,
				observation_version):
		return ProtocolError.make(ProtocolError.INTERNAL_ERROR,
			new_env.last_error, request_id, null)

	env = new_env
	_episode_seq += 1
	current_episode_id = _episode_seq
	episode_ended = false
	episode_owner = session.connection_id
	print("rl_server: reset episode=%d seed=%d scenario=%s agents=%d obs_v=%d" % [
		current_episode_id, seed, scenario_name, agent_count,
		observation_version])
	var result := {
		"episode_id": current_episode_id,
		"observation_version": observation_version,
		"observations": _observations_json(_episode_observations()),
		"active_mask": _active_mask_json(env.sim),
		"info": {"seed": seed, "steps": 0},
	}
	return ProtocolCodec.build_result(request_id, current_episode_id, result)


## STEP: validates the batched actions and advances the live episode by one
## policy step.
func handle_step(request: Dictionary) -> Dictionary:
	var request_id: Variant = request.get("request_id")
	var episode_id: Variant = request.get("episode_id")
	if env == null:
		if _episode_seq == 0:
			return ProtocolError.make(ProtocolError.NO_ACTIVE_EPISODE,
				"no active episode; send RESET first", request_id, episode_id)
		return ProtocolError.make(ProtocolError.STALE_EPISODE,
			"episode was abandoned (owner disconnected); send RESET",
			request_id, episode_id)
	if not ProtocolCodec.is_integral_number(episode_id) \
			or int(episode_id) != current_episode_id:
		return ProtocolError.make(ProtocolError.STALE_EPISODE,
			"episode_id %s is not the current episode %d" % [
				str(episode_id), current_episode_id],
			request_id, episode_id)
	if episode_ended:
		return ProtocolError.make(ProtocolError.EPISODE_ENDED,
			"episode %d has ended; send RESET to start a new one" \
				% current_episode_id,
			request_id, episode_id)

	var payload: Variant = _payload_object(request)
	if payload == null:
		return ProtocolError.make(ProtocolError.MISSING_FIELD,
			"payload must be an object", request_id, episode_id)
	var agent_count: int = env.sim.agent_count()
	var actions_v: Variant = payload.get("actions")
	if not (actions_v is Array) or actions_v.size() != agent_count:
		return ProtocolError.make(ProtocolError.INVALID_ACTION_SHAPE,
			"Expected %d actions for %d active agents." % [
				agent_count, agent_count],
			request_id, episode_id)
	var actions: Array = []
	for i in range(agent_count):
		var action_v: Variant = actions_v[i]
		if not (action_v is Array) or action_v.size() != DroneDynamics.ACTION_SIZE:
			return ProtocolError.make(ProtocolError.INVALID_ACTION_SHAPE,
				"action %d must have %d components" % [
					i, DroneDynamics.ACTION_SIZE],
				request_id, episode_id)
		var action := PackedFloat32Array()
		action.resize(DroneDynamics.ACTION_SIZE)
		for j in range(DroneDynamics.ACTION_SIZE):
			var component: Variant = action_v[j]
			if typeof(component) != TYPE_INT and typeof(component) != TYPE_FLOAT:
				return ProtocolError.make(ProtocolError.INVALID_ACTION_VALUE,
					"action %d component %d must be a number" % [i, j],
					request_id, episode_id)
			action[j] = float(component)
			if not is_finite(action[j]):
				return ProtocolError.make(ProtocolError.INVALID_ACTION_VALUE,
					"action %d component %d must be finite" % [i, j],
					request_id, episode_id)
		actions.append(action)

	if not env.apply_actions(actions):
		return ProtocolError.make(ProtocolError.INTERNAL_ERROR,
			env.last_error, request_id, episode_id)
	var t0 := Time.get_ticks_usec()
	if not env.step():
		return ProtocolError.make(ProtocolError.INTERNAL_ERROR,
			env.last_error, request_id, episode_id)
	var step_time_usec := Time.get_ticks_usec() - t0
	var terminated := env.is_terminated()
	var truncated := env.is_truncated()
	episode_ended = terminated or truncated

	var rewards := env.get_rewards()
	var rewards_json: Array = []
	var team_reward := 0.0
	for r in rewards:
		rewards_json.append(r)
		team_reward += r
	var info := env.get_info()
	var result := {
		"episode_id": current_episode_id,
		"observation_version": env.observation_version,
		"observations": _observations_json(_episode_observations()),
		"rewards": rewards_json,
		"team_reward": team_reward,
		"terminated": terminated,
		"truncated": truncated,
		"active_mask": _active_mask_json(env.sim),
		"info": {
			"steps": info["steps"],
			"successes": info["successes"],
			"collisions": info["collisions"],
			"mean_distance_to_target": info["mean_distance_to_target"],
			"seed": info["seed"],
			"state_hash": _hash_state(),
			"step_time_usec": step_time_usec,
		},
	}
	return ProtocolCodec.build_result(request_id, current_episode_id, result)


## PING: liveness probe; reports the server clock and live episode (or null).
func handle_ping(request: Dictionary) -> Dictionary:
	var live_episode: Variant = current_episode_id if env != null else null
	var result := {
		"pong": true,
		"server_time_msec": Time.get_ticks_msec(),
		"episode_id": live_episode,
	}
	return ProtocolCodec.build_result(request.get("request_id"),
		request.get("episode_id"), result)


## CLOSE: normal ok response; the transport closes the connection afterwards.
func handle_close(request: Dictionary) -> Dictionary:
	return ProtocolCodec.build_result(request.get("request_id"),
		request.get("episode_id"), {"closing": true})


# ---------------------------------------------------------------- transport


func _accept_pending() -> void:
	while _server.is_connection_available():
		var peer := _server.take_connection()
		# Latency-sensitive RPC: disable Nagle so back-to-back responses are
		# not held behind unacked segments (TCP_NODELAY).
		peer.set_no_delay(true)
		if _clients.size() >= max_clients:
			print("rl_server: rejecting extra connection from %s:%d (max_clients=%d)" % [
				peer.get_connected_host(), peer.get_connected_port(), max_clients])
			peer.disconnect_from_host()
			continue
		var client := Client.new(_next_client_id, peer, self)
		_next_client_id += 1
		_clients.append(client)
		print("rl_server: client %d connected from %s:%d" % [
			client.id, peer.get_connected_host(), peer.get_connected_port()])


## Services one client once. Returns false when the connection must be
## dropped (peer gone, framing violation, fatal decode error, or CLOSE).
func _service_client(client: Client) -> bool:
	client.peer.poll()
	if client.peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return false
	var available := client.peer.get_available_bytes()
	if available <= 0:
		return true
	var res: Array = client.peer.get_partial_data(available)
	if res[0] != OK:
		return false
	var chunk: PackedByteArray = res[1]
	var frames: Array = client.framer.feed(chunk)
	if client.framer.violated:
		print("rl_server: client %d framing violation; closing" % client.id)
		return false
	for frame in frames:
		var frame_bytes: PackedByteArray = frame
		if not _handle_payload(client, frame_bytes):
			return false
	return true


## Decodes, dispatches and answers one framed payload. Returns false when
## the connection must be dropped (fatal decode error or CLOSE handled).
func _handle_payload(client: Client, payload: PackedByteArray) -> bool:
	var decoded: Dictionary = ProtocolCodec.decode_request(payload)
	if not decoded["ok"] and decoded["fatal"]:
		print("rl_server: client %d sent invalid UTF-8; closing" % client.id)
		return false
	var response: Dictionary
	if decoded["ok"]:
		response = client.session.handle(decoded["request"])
	else:
		response = decoded["response"]
	var bytes := JSON.stringify(response).to_utf8_buffer()
	var err := client.peer.put_data(MessageFramer.encode_frame(bytes))
	if err != OK:
		print("rl_server: client %d write failed (error %d); closing" % [client.id, err])
		return false
	if client.session.close_requested:
		print("rl_server: client %d requested close" % client.id)
		return false
	return true


## Drops a client: logs, abandons the episode it owned (if any) and closes
## the socket. The episode ID counter is never reset.
func _remove_client(client: Client) -> void:
	print("rl_server: client %d disconnected" % client.id)
	if episode_owner == client.id:
		if env != null:
			print("rl_server: abandoning episode %d (owner disconnected)" \
				% current_episode_id)
		env = null
		current_episode_id = 0
		episode_ended = false
		episode_owner = -1
	client.peer.disconnect_from_host()
	_clients.erase(client)


# ---------------------------------------------------------------- helpers


## Per-agent observation vectors for the live episode's negotiated contract.
func _episode_observations() -> Array:
	if env.observation_version == ObservationV2.VERSION:
		return env.get_observations_v2()
	return env.get_observations()


## The request payload as a Dictionary; null when it is present but not an
## object. A missing or explicit-null payload counts as an empty object.
func _payload_object(request: Dictionary) -> Variant:
	var payload: Variant = request.get("payload")
	if payload == null:
		return {}
	if payload is Dictionary:
		return payload
	return null


## Array of PackedFloat32Array -> Array of Array of float (JSON-safe).
func _observations_json(observations: Array) -> Array:
	var out: Array = []
	for observation in observations:
		var packed: PackedFloat32Array = observation
		var row: Array = []
		row.resize(packed.size())
		for i in range(packed.size()):
			row[i] = packed[i]
		out.append(row)
	return out


## 1/0 active flags in stable spawn order.
func _active_mask_json(sim: SwarmSimulation) -> Array:
	var mask: Array = []
	for s in sim.states:
		mask.append(1 if s.active else 0)
	return mask


## SHA-256 hex of the packed logical state, identical to what the Phase 1
## headless runner prints as STATE_HASH.
func _hash_state() -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(env.sim.snapshot_packed().to_byte_array())
	return ctx.finish().hex_encode()
