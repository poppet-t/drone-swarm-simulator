#!/usr/bin/env bash
# Phase 2 smoke test: one command to verify the whole milestone.
#
#   1. Phase 1 regression suite (unit tests, headless run, determinism)
#      — includes the textured-asset load tests (test_visual_textured.gd)
#   2. Godot RL server startup on loopback + readiness line + PING
#   3. Julia unit tests (framing, protocol errors, mock server)
#   4. Julia-to-Godot integration tests (HELLO/GET_SPEC/RESET/STEP,
#      1000-step rollout, TCP determinism replay, error paths)
#   5. Clean shutdown: no Godot or Julia processes left behind
set -euo pipefail

cd "$(dirname "$0")/.."

GODOT="${GODOT:-godot}"
JULIA="${JULIA:-julia}"

echo "== 1/5 Phase 1 regression + textured asset tests =="
bash scripts/run_headless_smoke_test.sh

echo "== 2/5 Godot RL server startup check =="
PORT="$(python3 - <<'EOF'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
EOF
)"
LOG="$(mktemp /tmp/rl_server_smoke.XXXXXX.log)"
"$GODOT" --headless --path simulator -s res://src/networking/rl_server.gd -- \
  --host=127.0.0.1 --port="$PORT" --max-clients=1 >"$LOG" 2>&1 &
SERVER_PID=$!
cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  rm -f "$LOG"
}
trap cleanup EXIT

ready=""
for _ in $(seq 1 300); do
  if grep -q "^RL_SERVER_READY" "$LOG" 2>/dev/null; then
    ready="$(grep "^RL_SERVER_READY" "$LOG")"
    break
  fi
  sleep 0.1
done
if [ -z "$ready" ]; then
  echo "SERVER STARTUP FAILURE — log follows:" >&2
  cat "$LOG" >&2
  exit 1
fi
echo "$ready"

python3 - "$PORT" <<'EOF'
import json, socket, struct, sys

port = int(sys.argv[1])

def frame(payload):
    data = json.dumps(payload).encode()
    return struct.pack(">I", len(data)) + data

def recv_msg(sock):
    hdr = b""
    while len(hdr) < 4:
        hdr += sock.recv(4 - len(hdr))
    (n,) = struct.unpack(">I", hdr)
    body = b""
    while len(body) < n:
        body += sock.recv(n - len(body))
    return json.loads(body)

s = socket.create_connection(("127.0.0.1", port), timeout=10)
s.sendall(frame({"protocol_version": 1, "request_id": 1, "command": "HELLO",
                 "episode_id": None,
                 "payload": {"client_name": "phase2-smoke", "client_version": "1",
                             "supported_protocol_versions": [1]}}))
r = recv_msg(s)
assert r["ok"] and r["result"]["protocol_version"] == 1, r
s.sendall(frame({"protocol_version": 1, "request_id": 2, "command": "PING",
                 "episode_id": None, "payload": {}}))
r = recv_msg(s)
assert r["ok"] and r["result"]["pong"], r
s.sendall(frame({"protocol_version": 1, "request_id": 3, "command": "CLOSE",
                 "episode_id": None, "payload": {}}))
r = recv_msg(s)
assert r["ok"] and r["result"]["closing"], r
s.close()
print("HELLO/PING/CLOSE OK")
EOF

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT
rm -f "$LOG"

echo "== 3/5 Julia unit + 4/5 integration tests (spawns own servers) =="
"$JULIA" --project=julia -e 'using Pkg; Pkg.instantiate()' >/dev/null
"$JULIA" --project=julia julia/test/runtests.jl

echo "== 5/5 No leftover processes =="
# Give killed processes a moment to exit, then verify.
sleep 1
LEFTOVER="$(pgrep -af 'rl_server.gd|DroneSwarmRL|random_policy_client' || true)"
if [ -n "$LEFTOVER" ]; then
  echo "LEFTOVER PROCESSES:" >&2
  echo "$LEFTOVER" >&2
  exit 1
fi
echo "clean"

echo "PHASE 2 SMOKE TEST OK"
