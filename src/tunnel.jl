# tunnel.jl — SSH reverse tunnel manager

struct TunnelConfig
    host::String
    port::Int
    ssh_options::Vector{String}
end

TunnelConfig(host::String, port::Int; ssh_options::Vector{String}=String[]) =
    TunnelConfig(host, port, ssh_options)

mutable struct TunnelState
    process::Base.Process
    config::TunnelConfig
end

function build_ssh_command(cfg::TunnelConfig)
    args = String[]
    append!(args, ["-R", "$(cfg.port):localhost:$(cfg.port)"])
    append!(args, ["-N"])
    append!(args, ["-o", "ExitOnForwardFailure=yes"])
    append!(args, ["-o", "ServerAliveInterval=30"])
    append!(args, cfg.ssh_options)
    push!(args, cfg.host)
    return `ssh $args`
end

function start_tunnel(host::String; port::Int=8080, ssh_options::Vector{String}=String[])
    cfg = TunnelConfig(host, port; ssh_options)
    cmd = build_ssh_command(cfg)
    println("Starting SSH tunnel: $cmd")
    proc = open(cmd)
    sleep(1)
    if !process_running(proc)
        error("SSH tunnel failed to start. Check your SSH configuration and credentials.")
    end
    println("SSH tunnel active: HPC:$(port) → localhost:$(port)")
    return TunnelState(proc, cfg)
end

function stop_tunnel(state::TunnelState)
    if process_running(state.process)
        kill(state.process)
        println("SSH tunnel stopped.")
    end
end

function tunnel_alive(state::TunnelState)
    return process_running(state.process)
end
