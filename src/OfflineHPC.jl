module OfflineHPC

export serve, stop, set_verbose

include("proxy.jl")
include("tunnel.jl")

mutable struct ServerState
    proxy::ProxyState
    tunnel::Union{TunnelState, Nothing}
end

"""
    serve(; port=8080)

Start only the local HTTP proxy (no SSH tunnel).
Useful when you manage the SSH tunnel yourself.
"""
function serve(; port::Int=8080)
    proxy = start_proxy(; port)
    println("[OfflineHPC] Proxy listening on localhost:$(proxy.port)")
    println("[OfflineHPC] Run: ssh -R $(proxy.port):localhost:$(proxy.port) user@hpc")
    return ServerState(proxy, nothing)
end

"""
    serve(host; port=8080, ssh_options=String[])

Start the local HTTP proxy AND open an SSH reverse tunnel to `host`.
One command to set up everything on the local side.
"""
function serve(host::String; port::Int=8080, ssh_options::Vector{String}=String[])
    proxy = start_proxy(; port)
    println("[OfflineHPC] Proxy listening on localhost:$(proxy.port)")
    tunnel = start_tunnel(host; port=proxy.port, ssh_options)
    println("[OfflineHPC] Ready! On HPC, run:")
    println("  include(\"connect.jl\"); OfflineHPCClient.connect(port=$(proxy.port))")
    return ServerState(proxy, tunnel)
end

"""
    stop(state)

Stop the proxy server and SSH tunnel.
"""
function stop(state::ServerState)
    stop_proxy(state.proxy)
    if state.tunnel !== nothing
        stop_tunnel(state.tunnel)
    end
    println("[OfflineHPC] Stopped.")
end

end # module
