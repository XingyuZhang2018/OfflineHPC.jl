using Test
using OfflineHPC: build_ssh_command, TunnelConfig

@testset "build_ssh_command" begin
    cfg = TunnelConfig("user@hpc.example.com", 8080)
    cmd = build_ssh_command(cfg)
    cmd_str = string(cmd)
    @test contains(cmd_str, "-R")
    @test contains(cmd_str, "8080")
    @test contains(cmd_str, "user@hpc.example.com")
    @test contains(cmd_str, "-N")
end

@testset "build_ssh_command with options" begin
    cfg = TunnelConfig("hpc", 9090; ssh_options=["-o", "StrictHostKeyChecking=no"])
    cmd = build_ssh_command(cfg)
    cmd_str = string(cmd)
    @test contains(cmd_str, "9090")
    @test contains(cmd_str, "StrictHostKeyChecking")
end
