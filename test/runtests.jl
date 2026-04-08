using Test

@testset "OfflineHPC.jl" begin
    include("test_proxy.jl")
    include("test_connect.jl")
    include("test_tunnel.jl")
end
