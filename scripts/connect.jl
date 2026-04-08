# OfflineHPC Client — standalone file for air-gapped HPC systems
# Usage: include("connect.jl"); OfflineHPCClient.connect()
#
# Zero dependencies. Only uses Julia stdlib.
# Copy this single file to your HPC system via scp.

module OfflineHPCClient

import Sockets

const PROXY_KEYS = ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"]
const PKG_KEYS = ["JULIA_PKG_USE_CLI_GIT"]
const ALL_KEYS = vcat(PROXY_KEYS, PKG_KEYS)

const _original_env = Dict{String,Union{String,Nothing}}()
const _git_proxy_was_set = Ref(false)

function connect(; port::Int=8080, check::Bool=true)
    proxy = "http://localhost:$(port)"
    for k in ALL_KEYS
        _original_env[k] = get(ENV, k, nothing)
    end
    for k in PROXY_KEYS
        ENV[k] = proxy
    end
    ENV["JULIA_PKG_USE_CLI_GIT"] = "true"
    # Do NOT set JULIA_PKG_SERVER="" — let Pkg use the default Pkg Server
    # (HTTP downloads via proxy) instead of git clone (which libgit2 can't proxy)
    delete!(ENV, "JULIA_PKG_SERVER")
    # Configure git to use the proxy (for packages that require git clone)
    try
        run(`git config --global http.proxy $proxy`)
        run(`git config --global https.proxy $proxy`)
        _git_proxy_was_set[] = true
    catch
        println("[OfflineHPC] Warning: could not set git proxy config")
    end
    println("[OfflineHPC] Proxy configured → localhost:$(port)")
    if check
        if _check_tunnel(port)
            println("[OfflineHPC] Tunnel is active")
        else
            println("[OfflineHPC] Tunnel not detected. Is serve() running on local machine?")
        end
    end
    return nothing
end

function disconnect()
    for k in ALL_KEYS
        orig = get(_original_env, k, nothing)
        if orig === nothing
            delete!(ENV, k)
        else
            ENV[k] = orig
        end
    end
    empty!(_original_env)
    # Remove git proxy config
    if _git_proxy_was_set[]
        try
            run(`git config --global --unset http.proxy`)
            run(`git config --global --unset https.proxy`)
            _git_proxy_was_set[] = false
        catch; end
    end
    println("[OfflineHPC] Proxy disconnected")
    return nothing
end

function status()
    if haskey(ENV, "HTTP_PROXY") && startswith(get(ENV, "HTTP_PROXY", ""), "http://localhost")
        return :connected
    end
    return :disconnected
end

function _check_tunnel(port::Int)
    try
        sock = Sockets.connect(Sockets.IPv4("127.0.0.1"), port)
        close(sock)
        return true
    catch
        return false
    end
end

end # module OfflineHPCClient
