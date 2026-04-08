# proxy.jl — HTTP forward proxy with CONNECT support

using Sockets

const VERBOSE = Ref(false)

function set_verbose(v::Bool)
    VERBOSE[] = v
end

# ---------------------------------------------------------------------------
# Parsing helpers
# ---------------------------------------------------------------------------

"""
    parse_request_line(line::AbstractString) -> (method, target, version)

Split an HTTP request line into its three components.
"""
function parse_request_line(line::AbstractString)
    parts = split(strip(line), ' ', limit=3)
    length(parts) == 3 || error("malformed request line: $line")
    return (String(parts[1]), String(parts[2]), String(parts[3]))
end

"""
    parse_headers(io::IO) -> Dict{String,String}

Read RFC-style headers from `io` until a blank line (`\\r\\n`).
"""
function parse_headers(io::IO)
    headers = Dict{String,String}()
    while true
        raw = readline(io; keep=false)
        # An empty line (after stripping \\r) signals end of headers.
        line = rstrip(raw, '\r')
        isempty(line) && break
        idx = findfirst(':', line)
        idx === nothing && continue
        key   = strip(line[1:idx-1])
        value = strip(line[idx+1:end])
        headers[key] = value
    end
    return headers
end

"""
    parse_target_url(url::AbstractString) -> (host, port, path)

Parse an absolute HTTP URL into host, port (default 80), and path (default "/").
"""
function parse_target_url(url::AbstractString)
    # Determine default port from scheme
    default_port = startswith(url, "https://") ? 443 : 80
    # Strip the scheme prefix
    rest = replace(url, r"^https?://" => "")
    # Split host+port from path
    slash = findfirst('/', rest)
    if slash === nothing
        hostport = rest
        path = "/"
    else
        hostport = rest[1:slash-1]
        path = rest[slash:end]
    end
    # Split host from port
    colon = findfirst(':', hostport)
    if colon === nothing
        host = hostport
        port = default_port
    else
        host = hostport[1:colon-1]
        port = parse(Int, hostport[colon+1:end])
    end
    return (String(host), port, String(path))
end

"""
    parse_connect_target(target::AbstractString) -> (host, port)

Parse a CONNECT target (`host:port`) into its components.
"""
function parse_connect_target(target::AbstractString)
    colon = findlast(':', target)
    colon === nothing && error("malformed CONNECT target: $target")
    host = target[1:colon-1]
    port = parse(Int, target[colon+1:end])
    return (String(host), port)
end

# ---------------------------------------------------------------------------
# Bidirectional relay
# ---------------------------------------------------------------------------

"""
    _copy_until_done!(src::IO, dst::IO, done::Threads.Atomic{Bool})

Copy bytes from `src` to `dst` until `src` is closed/EOF or `done` is set.
"""
function _copy_until_done!(src::IO, dst::IO, done::Threads.Atomic{Bool})
    try
        while !done[]
            if eof(src)        # blocks until data or EOF; returns true at EOF
                break
            end
            nb = bytesavailable(src)
            nb == 0 && continue
            data = read(src, nb)
            write(dst, data)
            flush(dst)
        end
    catch e
        (e isa Base.IOError || e isa EOFError) || rethrow(e)
    finally
        done[] = true
        # Close dst so the other direction's eof() unblocks
        try close(dst) catch end
    end
end

"""
    relay!(a::IO, b::IO)

Copy data bidirectionally between two IO streams until one side closes.
"""
function relay!(a::IO, b::IO)
    done = Threads.Atomic{Bool}(false)
    t1 = @async _copy_until_done!(a, b, done)
    t2 = @async _copy_until_done!(b, a, done)
    wait(t1)
    wait(t2)
    return nothing
end

# ---------------------------------------------------------------------------
# Proxy server
# ---------------------------------------------------------------------------

"""
    ProxyState

Holds the running state of the forward proxy.
"""
mutable struct ProxyState
    server::Sockets.TCPServer
    port::Int
    running::Threads.Atomic{Bool}
    task::Task
end

"""
    handle_http(client, method, url, version, headers)

Forward a plain HTTP request (non-CONNECT) to the upstream server and relay
the response back to the client.
"""
function handle_http(client::IO, method::String, url::String, version::String, headers::Dict{String,String})
    VERBOSE[] && println("[proxy] $method $url")
    host, port, path = parse_target_url(url)
    upstream = nothing
    try
        upstream = Sockets.connect(host, port)
        # Build the request with a relative path
        write(upstream, "$method $path $version\r\n")
        for (k, v) in headers
            write(upstream, "$k: $v\r\n")
        end
        write(upstream, "\r\n")
        flush(upstream)

        # Relay the full response back to the client
        relay!(upstream, client)
    catch e
        if !(e isa Base.IOError || e isa EOFError)
            @warn "handle_http error" exception=(e, catch_backtrace())
            try
                write(client, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
            catch
            end
        end
    finally
        upstream !== nothing && try close(upstream) catch end
    end
end

"""
    handle_connect(client, target, version, headers)

Handle an HTTP CONNECT request: establish a TCP connection to the target,
send "200 Connection Established", then relay bidirectionally.
"""
function handle_connect(client::IO, target::String, version::String, headers::Dict{String,String})
    VERBOSE[] && println("[proxy] CONNECT → $target")
    host, port = parse_connect_target(target)
    upstream = nothing
    try
        upstream = Sockets.connect(host, port)
        write(client, "HTTP/1.1 200 Connection Established\r\n\r\n")
        flush(client)
        relay!(upstream, client)
    catch e
        if !(e isa Base.IOError || e isa EOFError)
            @warn "handle_connect error" exception=(e, catch_backtrace())
            try
                write(client, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
            catch
            end
        end
    finally
        upstream !== nothing && try close(upstream) catch end
    end
end

"""
    start_proxy(; port=8080) -> ProxyState

Start the HTTP forward proxy on the given port (use 0 for a random port).
Returns a `ProxyState` that can be passed to `stop_proxy`.
"""
function start_proxy(; port::Int=8080)
    server = Sockets.listen(IPv4("127.0.0.1"), port)
    actual_port = Int(getsockname(server)[2])
    println("[proxy] Listening on port $(actual_port)")
    running = Threads.Atomic{Bool}(true)

    task = @async begin
        while running[]
            local client
            try
                client = accept(server)
            catch e
                # Server was closed — normal shutdown path
                break
            end
            @async begin
                try
                    # Read the request line
                    request_line = readline(client; keep=false)
                    isempty(request_line) && return
                    method, target, version = parse_request_line(request_line)
                    headers = parse_headers(client)

                    if method == "CONNECT"
                        handle_connect(client, target, version, headers)
                    else
                        handle_http(client, method, target, version, headers)
                    end
                catch e
                    e isa Base.IOError || e isa EOFError || @debug "proxy handler error" exception=(e, catch_backtrace())
                finally
                    try close(client) catch end
                end
            end
        end
    end

    return ProxyState(server, actual_port, running, task)
end

"""
    stop_proxy(state::ProxyState)

Shut down a running proxy server.
"""
function stop_proxy(state::ProxyState)
    state.running[] = false
    try close(state.server) catch end
    # Give the accept loop time to notice the closed server
    try wait(state.task) catch end
    return nothing
end
