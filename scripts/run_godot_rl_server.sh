#!/usr/bin/env bash
# Launch the Godot RL TCP server (Phase 2 Julia bridge).
#
# Defaults: loopback only, port 9100, single client. Override with env:
#   HOST=127.0.0.1 PORT=9100 MAX_CLIENTS=1 bash scripts/run_godot_rl_server.sh
#
# The server prints a machine-readable readiness line:
#   RL_SERVER_READY host=127.0.0.1 port=9100 protocol=1
# Protocol contract: docs/network_protocol.md.
set -euo pipefail

cd "$(dirname "$0")/.."

GODOT="${GODOT:-godot}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-9100}"
MAX_CLIENTS="${MAX_CLIENTS:-1}"

exec "$GODOT" --headless --path simulator -s res://src/networking/rl_server.gd -- \
  --host="$HOST" \
  --port="$PORT" \
  --max-clients="$MAX_CLIENTS"
