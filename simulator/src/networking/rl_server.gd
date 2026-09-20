extends SceneTree

## TCP RL server for the Julia client (protocol v1). Usage:
##   godot --headless --path simulator -s res://src/networking/rl_server.gd -- \
##       --host=127.0.0.1 --port=9100 --max-clients=1
##
## Thin CLI wrapper around RLServerCore: parses arguments, starts the server,
## prints one machine-readable ready line and pumps poll() until killed.
## --host defaults to loopback on purpose; never bind 0.0.0.0 unless asked.

var _core: RLServerCore


func _initialize() -> void:
	# Pacing comes from the engine's low-processor mode, NOT a manual sleep:
	# headless Godot forces that mode on with its default 6900 us frame sleep,
	# which alone put ~6.9 ms on every round trip (Phase 3 profiling). 300 us
	# bounds socket-pickup latency while keeping idle CPU usage near zero;
	# poll() drains every available complete frame per iteration, so
	# throughput is unaffected.
	OS.low_processor_usage_mode_sleep_usec = 300
	var opts := _parse_args(OS.get_cmdline_user_args())
	_core = RLServerCore.new()
	_core.host = str(opts.get("host", "127.0.0.1"))
	_core.port = int(str(opts.get("port", "9100")))
	_core.max_clients = int(str(opts.get("max-clients", "1")))
	if not _core.start():
		quit(1)
		return
	print("RL_SERVER_READY host=%s port=%d protocol=1" % [_core.host, _core.port])


func _process(_delta: float) -> bool:
	_core.poll()
	return false


func _finalize() -> void:
	_core.stop()


func _parse_args(args: PackedStringArray) -> Dictionary:
	var opts := {}
	for arg in args:
		if arg.begins_with("--"):
			var kv := arg.trim_prefix("--").split("=", true, 1)
			if kv.size() == 2:
				opts[kv[0]] = kv[1]
			else:
				opts[kv[0]] = true
	return opts
