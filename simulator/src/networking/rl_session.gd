class_name RLSession
extends RefCounted
## Per-connection command handler of the RL TCP bridge (protocol v1).
##
## One session per connection. Enforces the session gate (HELLO must be the
## first command) and dispatches commands to the shared RLServerCore, which
## owns all episode state. Socket-free: the transport feeds it normalized
## request Dictionaries from ProtocolCodec and sends back the returned
## response envelopes.

## True once HELLO completed successfully on this connection.
var hello_done := false
## Set when CLOSE was handled; the transport sends the response, then closes.
var close_requested := false
## Transport-assigned connection id; the core tracks episode ownership with
## it. 0 for sessions driven directly by tests.
var connection_id := 0

var _core: RLServerCore


func _init(core: RLServerCore) -> void:
	_core = core


## Handles one normalized request and returns the response envelope.
func handle(request: Dictionary) -> Dictionary:
	var request_id: Variant = request.get("request_id")
	var episode_id: Variant = request.get("episode_id")
	var command_v: Variant = request.get("command")
	if not (command_v is String):
		return ProtocolError.make(ProtocolError.MISSING_FIELD,
			"command must be a string", request_id, episode_id)
	var command: String = command_v
	if not hello_done and command != "HELLO":
		return ProtocolError.make(ProtocolError.EXPECTED_HELLO,
			"the first command on a connection must be HELLO",
			request_id, episode_id)
	match command:
		"HELLO":
			return _core.handle_hello(self, request)
		"GET_SPEC":
			return _core.handle_get_spec(request)
		"RESET":
			return _core.handle_reset(self, request)
		"STEP":
			return _core.handle_step(request)
		"PING":
			return _core.handle_ping(request)
		"CLOSE":
			close_requested = true
			return _core.handle_close(request)
	return ProtocolError.make(ProtocolError.UNKNOWN_COMMAND,
		"unknown command '%s'" % command, request_id, episode_id)
