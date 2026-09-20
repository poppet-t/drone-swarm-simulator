# Test entry point. Pure-Julia protocol/mock tests always run; integration
# tests skip gracefully when no godot binary is available.
#
# Run from the repo root:
#   julia --project=julia julia/test/runtests.jl

using Test
using DroneSwarmRL

@testset "DroneSwarmRL" verbose = true begin
    include("protocol_tests.jl")
    include("integration_tests.jl")
end
