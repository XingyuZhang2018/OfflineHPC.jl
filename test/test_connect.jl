using Test

include(joinpath(@__DIR__, "..", "scripts", "connect.jl"))

@testset "OfflineHPCClient.connect sets env vars" begin
    for k in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy",
              "JULIA_PKG_USE_CLI_GIT"]
        delete!(ENV, k)
    end
    OfflineHPCClient.connect(port=9999, check=false)
    @test ENV["HTTP_PROXY"] == "http://localhost:9999"
    @test ENV["HTTPS_PROXY"] == "http://localhost:9999"
    @test ENV["http_proxy"] == "http://localhost:9999"
    @test ENV["https_proxy"] == "http://localhost:9999"
    @test ENV["JULIA_PKG_USE_CLI_GIT"] == "true"
    @test !haskey(ENV, "JULIA_PKG_SERVER")
end

@testset "OfflineHPCClient.disconnect clears env vars" begin
    for k in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy",
              "JULIA_PKG_USE_CLI_GIT"]
        delete!(ENV, k)
    end
    OfflineHPCClient.connect(port=9999, check=false)
    OfflineHPCClient.disconnect()
    @test !haskey(ENV, "HTTP_PROXY")
    @test !haskey(ENV, "HTTPS_PROXY")
    @test !haskey(ENV, "http_proxy")
    @test !haskey(ENV, "https_proxy")
    @test !haskey(ENV, "JULIA_PKG_USE_CLI_GIT")
end

@testset "OfflineHPCClient.status" begin
    OfflineHPCClient.disconnect()
    @test OfflineHPCClient.status() == :disconnected
end
