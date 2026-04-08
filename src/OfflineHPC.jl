module OfflineHPC

export serve

include("proxy.jl")
include("tunnel.jl")

"""
    serve(host; port=8080)

Start the local HTTP proxy and open an SSH reverse tunnel to `host`.
The HPC side can then use `include("connect.jl"); OfflineHPCClient.connect(port=PORT)`
to route Julia Pkg traffic through this proxy.
"""
function serve(host::AbstractString; port::Int=8080)
    error("Not yet implemented")
end

end # module
