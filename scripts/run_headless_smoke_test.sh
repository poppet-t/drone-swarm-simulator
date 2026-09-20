#!/usr/bin/env bash
# Headless smoke test for the drone-swarm simulator.
# Verifies: project startup, unit tests, headless training run, determinism.
set -euo pipefail

cd "$(dirname "$0")/.."

GODOT="${GODOT:-godot}"

echo "== 1/4 Project startup (headless) =="
"$GODOT" --headless --path simulator --quit-after 5

echo "== 2/4 Unit tests =="
"$GODOT" --headless --path simulator -s res://tests/run_tests.gd

echo "== 3/4 Headless training run (waypoint, 4 agents, 1000 steps) =="
"$GODOT" --headless --path simulator -s res://src/cli/headless_runner.gd -- \
  --training --scenario=waypoint --seed=1234 --agents=4 --steps=1000

echo "== 4/4 Determinism (two identical seeded runs must hash equal) =="
run_once() {
  "$GODOT" --headless --path simulator -s res://src/cli/headless_runner.gd -- \
    --training --scenario=waypoint --seed=42 --agents=4 --steps=500 \
    --controller=random 2>/dev/null | grep '^STATE_HASH'
}
H1="$(run_once)"
H2="$(run_once)"
echo "run 1: $H1"
echo "run 2: $H2"
if [ "$H1" != "$H2" ]; then
  echo "DETERMINISM FAILURE: state hashes differ" >&2
  exit 1
fi

echo "SMOKE TEST OK"
