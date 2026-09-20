#!/usr/bin/env bash
# Instantiate the Julia environment and run the full DroneSwarmRL test suite
# (protocol unit tests + Julia-to-Godot integration tests).
#
# The integration tests spawn and kill their own headless Godot servers on
# free local ports; GODOT=... overrides the Godot executable.
set -euo pipefail

cd "$(dirname "$0")/.."

JULIA="${JULIA:-julia}"

"$JULIA" --project=julia -e 'using Pkg; Pkg.instantiate()'
exec "$JULIA" --project=julia julia/test/runtests.jl
