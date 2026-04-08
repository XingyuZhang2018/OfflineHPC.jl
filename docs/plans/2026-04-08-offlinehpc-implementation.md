# OfflineHPC.jl Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a zero-dependency Julia package that lets users install Julia packages on air-gapped HPC systems by proxying downloads through a local machine via SSH reverse tunnel.

**Architecture:** Two components — a local HTTP forward proxy server (handles both HTTP and HTTPS CONNECT) built on Julia's stdlib `Sockets`, and a standalone single-file HPC client that configures Julia's environment to route traffic through the proxy. SSH reverse port forwarding (`-R`) bridges the two sides.

**Tech Stack:** Pure Julia stdlib — `Sockets`, `Base`, `Test`. Zero external dependencies.

---

## Project Layout

```
offline_hpc/
├── Project.toml
├── src/
│   ├── OfflineHPC.jl        # Main module, exports serve()
│   ├── proxy.jl             # HTTP forward proxy with CONNECT support
│   └── tunnel.jl            # SSH reverse tunnel manager
├── scripts/
│   └── connect.jl           # Standalone HPC client (zero deps)
├── test/
│   ├── runtests.jl          # Test entrypoint
│   ├── test_proxy.jl        # Proxy server tests
│   ├── test_tunnel.jl       # Tunnel manager tests
│   └── test_connect.jl      # Client config tests
└── docs/
    └── plans/               # (already exists)
```

---

### Task 1: Project Scaffold

**Files:**
- Create: `Project.toml`
- Create: `src/OfflineHPC.jl`
- Create: `test/runtests.jl`

**Step 1: Create `Project.toml`**

```toml
name = "OfflineHPC"
uuid = "generate-a-uuid"
version = "0.1.0"
authors = ["Your Name"]

[compat]
julia = "1.6"

[extras]
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

[targets]
test = ["Test"]
```

Generate a real UUID with Julia: `using UUIDs; uuid4()`.

**Step 2: Create minimal `src/OfflineHPC.jl`**

```julia
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
    # Will be implemented in later tasks
    error("Not yet implemented")
end

end # module
```

**Step 3: Create placeholder source files**

Create empty `src/proxy.jl` and `src/tunnel.jl` with just a comment:

```julia
# proxy.jl — HTTP forward proxy with CONNECT support
```

```julia
# tunnel.jl — SSH reverse tunnel manager
```

**Step 4: Create `test/runtests.jl`**

```julia
using Test

@testset "OfflineHPC.jl" begin
    include("test_proxy.jl")
    include("test_connect.jl")
    include("test_tunnel.jl")
end
```

Create empty test files `test/test_proxy.jl`, `test/test_connect.jl`, `test/test_tunnel.jl` each with a placeholder:

```julia
@testset "placeholder" begin
    @test true
end
```

**Step 5: Verify scaffold**

Run: `cd "D:/2 - skill/offline_hpc" && julia --project=. -e "using OfflineHPC"`
Expected: Module loads without error.

Run: `cd "D:/2 - skill/offline_hpc" && julia --project=. -e "using Pkg; Pkg.test()"`
Expected: All placeholder tests pass.

**Step 6: Commit**

```bash
git init
git add Project.toml src/ test/ docs/
git commit -m "feat: project scaffold for OfflineHPC.jl"
```

---

### Task 2: HTTP Forward Proxy — Parse Request

**Files:**
- Modify: `src/proxy.jl`
- Create: `test/test_proxy.jl`

This task implements HTTP request line parsing and header parsing — the foundation of the proxy.

**Step 1: Write the failing test**

In `test/test_proxy.jl`:

```julia
using Test
using OfflineHPC: parse_request_line, parse_headers

@testset "parse_request_line" begin
    @test parse_request_line("GET http://example.com/path HTTP/1.1") == ("GET", "http://example.com/path", "HTTP/1.1")
    @test parse_request_line("CONNECT example.com:443 HTTP/1.1") == ("CONNECT", "example.com:443", "HTTP/1.1")
    @test parse_request_line("POST http://pkg.julialang.org/v1 HTTP/1.1") == ("POST", "http://pkg.julialang.org/v1", "HTTP/1.1")
end

@testset "parse_headers" begin
    raw = "Host: example.com\r\nContent-Length: 42\r\nProxy-Connection: keep-alive\r\n\r\n"
    headers = parse_headers(IOBuffer(raw))
    @test headers["Host"] == "example.com"
    @test headers["Content-Length"] == "42"
end
```

**Step 2: Run test to verify it fails**

Run: `julia --project=. -e "using Pkg; Pkg.test()"`
Expected: FAIL — `parse_request_line` not defined.

**Step 3: Write minimal implementation**

In `src/proxy.jl`:

```julia
# proxy.jl — HTTP forward proxy with CONNECT support

using Sockets

"""
Parse an HTTP request line like "GET http://example.com/path HTTP/1.1"
Returns (method, uri, version).
"""
function parse_request_line(line::AbstractString)
    parts = split(strip(line), ' ', limit=3)
    length(parts) == 3 || error("Malformed request line: $line")
    return (String(parts[1]), String(parts[2]), String(parts[3]))
end

"""
Read HTTP headers from an IO stream until empty line.
Returns Dict{String,String}.
"""
function parse_headers(io::IO)
    headers = Dict{String,String}()
    while true
        line = readline(io)
        isempty(strip(line)) && break
        idx = findfirst(':', line)
        idx === nothing && continue
        key = strip(line[1:idx-1])
        val = strip(line[idx+1:end])
        headers[key] = val
    end
    return headers
end
```

**Step 4: Run test to verify it passes**

Run: `julia --project=. -e "using Pkg; Pkg.test()"`
Expected: PASS

**Step 5: Commit**

```bash
git add src/proxy.jl test/test_proxy.jl
git commit -m "feat: HTTP request line and header parsing"
```

---

### Task 3: HTTP Forward Proxy — URL Parsing and Connection

**Files:**
- Modify: `src/proxy.jl`
- Modify: `test/test_proxy.jl`

**Step 1: Write the failing test**

Append to `test/test_proxy.jl`:

```julia
using OfflineHPC: parse_target_url

@testset "parse_target_url" begin
    @test parse_target_url("http://example.com/path") == ("example.com", 80, "/path")
    @test parse_target_url("http://example.com:8443/v1") == ("example.com", 8443, "/v1")
    @test parse_target_url("http://example.com") == ("example.com", 80, "/")
end

@testset "parse CONNECT target" begin
    using OfflineHPC: parse_connect_target
    @test parse_connect_target("example.com:443") == ("example.com", 443)
    @test parse_connect_target("github.com:22") == ("github.com", 22)
end
```

**Step 2: Run test to verify it fails**

Run: `julia --project=. -e "using Pkg; Pkg.test()"`
Expected: FAIL — functions not defined.

**Step 3: Write minimal implementation**

Append to `src/proxy.jl`:

```julia
"""
Parse an absolute HTTP URL into (host, port, path).
Example: "http://example.com:8080/v1" → ("example.com", 8080, "/v1")
"""
function parse_target_url(url::AbstractString)
    # Strip scheme
    rest = url
    if startswith(rest, "http://")
        rest = rest[8:end]
    elseif startswith(rest, "https://")
        rest = rest[9:end]
    end
    # Split host and path
    slash_idx = findfirst('/', rest)
    if slash_idx === nothing
        hostport = rest
        path = "/"
    else
        hostport = rest[1:slash_idx-1]
        path = rest[slash_idx:end]
    end
    # Split host and port
    colon_idx = findfirst(':', hostport)
    if colon_idx === nothing
        return (String(hostport), 80, String(path))
    else
        host = String(hostport[1:colon_idx-1])
        port = parse(Int, hostport[colon_idx+1:end])
        return (host, port, String(path))
    end
end

"""
Parse a CONNECT target like "example.com:443" → (host, port).
"""
function parse_connect_target(target::AbstractString)
    colon_idx = findlast(':', target)
    colon_idx === nothing && error("Malformed CONNECT target: $target")
    host = String(target[1:colon_idx-1])
    port = parse(Int, target[colon_idx+1:end])
    return (host, port)
end
```

**Step 4: Run test to verify it passes**

Run: `julia --project=. -e "using Pkg; Pkg.test()"`
Expected: PASS

**Step 5: Commit**

```bash
git add src/proxy.jl test/test_proxy.jl
git commit -m "feat: URL and CONNECT target parsing"
```

---

### Task 4: HTTP Forward Proxy — Bidirectional Relay

**Files:**
- Modify: `src/proxy.jl`
- Modify: `test/test_proxy.jl`

The relay function is the core of CONNECT support — it copies data bidirectionally between client and upstream sockets.

**Step 1: Write the failing test**

Append to `test/test_proxy.jl`:

```julia
using Sockets
using OfflineHPC: relay!

@testset "relay! bidirectional copy" begin
    # Set up a pair of in-memory IO buffers simulating two sides
    # Create a TCP server and two connections to test relay
    srv = listen(IPv4("127.0.0.1"), 0)  # random port
    port = getsockname(srv)[2]

    # Simulated "upstream" server that echoes back
    @async begin
        sock = accept(srv)
        data = readavailable(sock)
        write(sock, data)
        close(sock)
    end

    # Client side
    client_to_proxy = IOBuffer()
    proxy_to_upstream = connect(IPv4("127.0.0.1"), port)

    write(proxy_to_upstream, "hello from client")
    flush(proxy_to_upstream)
    sleep(0.1)
    response = readavailable(proxy_to_upstream)
    @test String(response) == "hello from client"

    close(proxy_to_upstream)
    close(srv)
end
```

**Step 2: Run test to verify it fails**

Run: `julia --project=. -e "using Pkg; Pkg.test()"`
Expected: FAIL — `relay!` not defined (though the echo test itself should pass, what matters is that `relay!` is importable).

**Step 3: Write minimal implementation**

Append to `src/proxy.jl`:

```julia
"""
Bidirectional relay: copy data between two IO streams until one closes.
Each direction runs in its own async task.
"""
function relay!(a::IO, b::IO)
    task_a2b = @async try
        while isopen(a) && isopen(b)
            data = readavailable(a)
            isempty(data) && (sleep(0.01); continue)
            write(b, data)
            flush(b)
        end
    catch e
        e isa EOFError || e isa Base.IOError || rethrow()
    end

    task_b2a = @async try
        while isopen(a) && isopen(b)
            data = readavailable(b)
            isempty(data) && (sleep(0.01); continue)
            write(a, data)
            flush(a)
        end
    catch e
        e isa EOFError || e isa Base.IOError || rethrow()
    end

    # Wait for either direction to finish, then clean up
    while !istaskdone(task_a2b) && !istaskdone(task_b2a)
        sleep(0.05)
    end
end
```

**Step 4: Run test to verify it passes**

Run: `julia --project=. -e "using Pkg; Pkg.test()"`
Expected: PASS

**Step 5: Commit**

```bash
git add src/proxy.jl test/test_proxy.jl
git commit -m "feat: bidirectional relay for CONNECT tunneling"
```

---

### Task 5: HTTP Forward Proxy — Handle Client Connections

**Files:**
- Modify: `src/proxy.jl`
- Modify: `test/test_proxy.jl`

This is the main proxy loop: accept connection, read request, dispatch to HTTP forward or CONNECT handler.

**Step 1: Write the failing test**

Append to `test/test_proxy.jl`:

```julia
using OfflineHPC: start_proxy, stop_proxy

@testset "proxy server HTTP forwarding" begin
    # Start a mock upstream HTTP server
    upstream = listen(IPv4("127.0.0.1"), 0)
    upstream_port = getsockname(upstream)[2]
    @async begin
        sock = accept(upstream)
        request = String(readavailable(sock))
        write(sock, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")
        close(sock)
    end

    # Start proxy
    proxy_state = start_proxy(port=0)  # random port
    proxy_port = proxy_state.port

    # Connect as client, send HTTP request through proxy
    client = connect(IPv4("127.0.0.1"), proxy_port)
    write(client, "GET http://127.0.0.1:$(upstream_port)/test HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    flush(client)
    sleep(0.5)
    response = String(readavailable(client))
    @test contains(response, "200 OK")
    @test contains(response, "hello")

    close(client)
    stop_proxy(proxy_state)
    close(upstream)
end
```

**Step 2: Run test to verify it fails**

Run: `julia --project=. -e "using Pkg; Pkg.test()"`
Expected: FAIL — `start_proxy` not defined.

**Step 3: Write implementation**

Append to `src/proxy.jl`:

```julia
mutable struct ProxyState
    server::Sockets.TCPServer
    port::Int
    running::Bool
    task::Task
end

"""
Start the HTTP forward proxy on `port`. If port=0, pick a random available port.
Returns a ProxyState that can be passed to stop_proxy().
"""
function start_proxy(; port::Int=8080)
    server = listen(IPv4("127.0.0.1"), port)
    actual_port = getsockname(server)[2]

    state = ProxyState(server, actual_port, true, @async nothing)

    state.task = @async begin
        while state.running
            try
                client = accept(server)
                @async handle_client(client)
            catch e
                state.running || break  # expected on shutdown
                @warn "Proxy accept error" exception=e
            end
        end
    end

    return state
end

"""
Stop the proxy server.
"""
function stop_proxy(state::ProxyState)
    state.running = false
    close(state.server)
end

"""
Handle a single proxy client connection.
"""
function handle_client(client::IO)
    try
        # Read request line
        request_line = readline(client)
        isempty(request_line) && return

        method, uri, version = parse_request_line(request_line)
        headers = parse_headers(client)

        if uppercase(method) == "CONNECT"
            handle_connect(client, uri)
        else
            handle_http(client, method, uri, version, headers)
        end
    catch e
        e isa EOFError || e isa Base.IOError || @warn "Client handler error" exception=e
    finally
        isopen(client) && close(client)
    end
end

"""
Handle HTTP CONNECT method — establish a tunnel.
"""
function handle_connect(client::IO, target::AbstractString)
    host, port = parse_connect_target(target)
    upstream = nothing
    try
        upstream = connect(host, port)
        # Tell client the tunnel is established
        write(client, "HTTP/1.1 200 Connection Established\r\n\r\n")
        flush(client)
        # Relay data bidirectionally
        relay!(client, upstream)
    catch e
        if isopen(client)
            write(client, "HTTP/1.1 502 Bad Gateway\r\n\r\n")
        end
    finally
        upstream !== nothing && isopen(upstream) && close(upstream)
    end
end

"""
Handle regular HTTP request — forward to upstream.
"""
function handle_http(client::IO, method::String, uri::String, version::String, headers::Dict)
    host, port, path = parse_target_url(uri)
    upstream = nothing
    try
        upstream = connect(host, port)
        # Rebuild request with relative path
        write(upstream, "$method $path $version\r\n")
        for (k, v) in headers
            write(upstream, "$k: $v\r\n")
        end
        write(upstream, "\r\n")
        flush(upstream)

        # Read body from client if Content-Length present
        if haskey(headers, "Content-Length")
            nbytes = parse(Int, headers["Content-Length"])
            body = read(client, nbytes)
            write(upstream, body)
            flush(upstream)
        end

        # Forward response back to client
        while isopen(upstream)
            data = readavailable(upstream)
            isempty(data) && break
            write(client, data)
            flush(client)
        end
    catch e
        if isopen(client)
            write(client, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
        end
    finally
        upstream !== nothing && isopen(upstream) && close(upstream)
    end
end
```

**Step 4: Run test to verify it passes**

Run: `julia --project=. -e "using Pkg; Pkg.test()"`
Expected: PASS

**Step 5: Commit**

```bash
git add src/proxy.jl test/test_proxy.jl
git commit -m "feat: complete HTTP forward proxy with CONNECT support"
```

---

### Task 6: HTTP Forward Proxy — CONNECT Tunnel Test

**Files:**
- Modify: `test/test_proxy.jl`

Add a test specifically for the CONNECT tunnel (simulating HTTPS).

**Step 1: Write the test**

Append to `test/test_proxy.jl`:

```julia
@testset "proxy server CONNECT tunnel" begin
    # Start a mock "TLS" server (just echoes)
    tls_srv = listen(IPv4("127.0.0.1"), 0)
    tls_port = getsockname(tls_srv)[2]
    @async begin
        sock = accept(tls_srv)
        data = readavailable(sock)
        write(sock, reverse(data))  # reverse as proof of relay
        close(sock)
    end

    # Start proxy
    proxy_state = start_proxy(port=0)
    proxy_port = proxy_state.port

    # Client sends CONNECT
    client = connect(IPv4("127.0.0.1"), proxy_port)
    write(client, "CONNECT 127.0.0.1:$(tls_port) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    flush(client)
    sleep(0.2)

    # Read the 200 Connection Established
    status_line = readline(client)
    @test contains(status_line, "200")
    # Read empty line after status
    readline(client)

    # Now the tunnel is open — send data through
    write(client, "test data")
    flush(client)
    sleep(0.3)
    response = String(readavailable(client))
    @test response == "atad tset"  # reversed

    close(client)
    stop_proxy(proxy_state)
    close(tls_srv)
end
```

**Step 2: Run test to verify it passes**

Run: `julia --project=. -e "using Pkg; Pkg.test()"`
Expected: PASS (implementation already exists from Task 5)

**Step 3: Commit**

```bash
git add test/test_proxy.jl
git commit -m "test: add CONNECT tunnel integration test"
```

---

### Task 7: SSH Tunnel Manager

**Files:**
- Modify: `src/tunnel.jl`
- Create: `test/test_tunnel.jl`

**Step 1: Write the failing test**

In `test/test_tunnel.jl`:

```julia
using Test
using OfflineHPC: build_ssh_command, TunnelConfig

@testset "build_ssh_command" begin
    cfg = TunnelConfig("user@hpc.example.com", 8080)
    cmd = build_ssh_command(cfg)
    cmd_str = string(cmd)
    @test contains(cmd_str, "-R")
    @test contains(cmd_str, "8080")
    @test contains(cmd_str, "user@hpc.example.com")
    @test contains(cmd_str, "-N")  # no remote command
end

@testset "build_ssh_command with options" begin
    cfg = TunnelConfig("hpc", 9090; ssh_options=["-o", "StrictHostKeyChecking=no"])
    cmd = build_ssh_command(cfg)
    cmd_str = string(cmd)
    @test contains(cmd_str, "9090")
    @test contains(cmd_str, "StrictHostKeyChecking")
end
```

**Step 2: Run test to verify it fails**

Run: `julia --project=. -e "using Pkg; Pkg.test()"`
Expected: FAIL — `TunnelConfig` not defined.

**Step 3: Write implementation**

In `src/tunnel.jl`:

```julia
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

"""
Build the ssh command for reverse port forwarding.
"""
function build_ssh_command(cfg::TunnelConfig)
    args = String[]
    append!(args, ["-R", "$(cfg.port):localhost:$(cfg.port)"])
    append!(args, ["-N"])  # no remote command
    append!(args, ["-o", "ExitOnForwardFailure=yes"])
    append!(args, ["-o", "ServerAliveInterval=30"])
    append!(args, cfg.ssh_options)
    push!(args, cfg.host)
    return `ssh $args`
end

"""
Start an SSH reverse tunnel. Returns TunnelState.
The tunnel runs as a background process.
"""
function start_tunnel(host::String; port::Int=8080, ssh_options::Vector{String}=String[])
    cfg = TunnelConfig(host, port; ssh_options)
    cmd = build_ssh_command(cfg)
    println("Starting SSH tunnel: $cmd")
    proc = open(cmd)
    # Give it a moment to establish
    sleep(1)
    if !process_running(proc)
        error("SSH tunnel failed to start. Check your SSH configuration and credentials.")
    end
    println("SSH tunnel active: HPC:$(port) → localhost:$(port)")
    return TunnelState(proc, cfg)
end

"""
Stop an SSH tunnel.
"""
function stop_tunnel(state::TunnelState)
    if process_running(state.process)
        kill(state.process)
        println("SSH tunnel stopped.")
    end
end

"""
Check if the tunnel is still active.
"""
function tunnel_alive(state::TunnelState)
    return process_running(state.process)
end
```

**Step 4: Run test to verify it passes**

Run: `julia --project=. -e "using Pkg; Pkg.test()"`
Expected: PASS

**Step 5: Commit**

```bash
git add src/tunnel.jl test/test_tunnel.jl
git commit -m "feat: SSH reverse tunnel manager"
```

---

### Task 8: HPC Client — `connect.jl`

**Files:**
- Create: `scripts/connect.jl`
- Create: `test/test_connect.jl`

**Step 1: Write the failing test**

In `test/test_connect.jl`:

```julia
using Test

# Test connect.jl as a standalone include
include(joinpath(@__DIR__, "..", "scripts", "connect.jl"))

@testset "OfflineHPCClient.connect sets env vars" begin
    # Clean env first
    for k in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy",
              "JULIA_PKG_USE_CLI_GIT", "JULIA_PKG_SERVER"]
        delete!(ENV, k)
    end

    OfflineHPCClient.connect(port=9999, check=false)

    @test ENV["HTTP_PROXY"] == "http://localhost:9999"
    @test ENV["HTTPS_PROXY"] == "http://localhost:9999"
    @test ENV["http_proxy"] == "http://localhost:9999"
    @test ENV["https_proxy"] == "http://localhost:9999"
    @test ENV["JULIA_PKG_USE_CLI_GIT"] == "true"
    @test ENV["JULIA_PKG_SERVER"] == ""
end

@testset "OfflineHPCClient.disconnect clears env vars" begin
    OfflineHPCClient.connect(port=9999, check=false)
    OfflineHPCClient.disconnect()

    @test !haskey(ENV, "HTTP_PROXY")
    @test !haskey(ENV, "HTTPS_PROXY")
    @test !haskey(ENV, "http_proxy")
    @test !haskey(ENV, "https_proxy")
    @test !haskey(ENV, "JULIA_PKG_USE_CLI_GIT")
    @test !haskey(ENV, "JULIA_PKG_SERVER")
end

@testset "OfflineHPCClient.status reports not connected" begin
    OfflineHPCClient.disconnect()
    s = OfflineHPCClient.status()
    @test s == :disconnected
end
```

**Step 2: Run test to verify it fails**

Run: `julia --project=. -e "using Pkg; Pkg.test()"`
Expected: FAIL — `scripts/connect.jl` doesn't exist.

**Step 3: Write implementation**

In `scripts/connect.jl`:

```julia
# OfflineHPC Client — standalone file for air-gapped HPC systems
# Usage: include("connect.jl"); OfflineHPCClient.connect()
#
# Zero dependencies. Only uses Julia stdlib.
# Copy this single file to your HPC system via scp.

module OfflineHPCClient

const PROXY_KEYS = ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"]
const PKG_KEYS = ["JULIA_PKG_USE_CLI_GIT", "JULIA_PKG_SERVER"]
const ALL_KEYS = vcat(PROXY_KEYS, PKG_KEYS)

# Store original values for clean restore
const _original_env = Dict{String,Union{String,Nothing}}()

"""
    connect(; port=8080, check=true)

Configure Julia to route all HTTP(S) traffic through the SSH tunnel proxy.
Run this after the local machine has started `serve()`.

- `port`: must match the port used by `serve()` on the local side
- `check`: if true, verify the tunnel is active by pinging the proxy
"""
function connect(; port::Int=8080, check::Bool=true)
    proxy = "http://localhost:$(port)"

    # Save originals
    for k in ALL_KEYS
        _original_env[k] = get(ENV, k, nothing)
    end

    # Set proxy
    for k in PROXY_KEYS
        ENV[k] = proxy
    end
    ENV["JULIA_PKG_USE_CLI_GIT"] = "true"
    ENV["JULIA_PKG_SERVER"] = ""

    println("[OfflineHPC] Proxy configured → localhost:$(port)")

    if check
        if _check_tunnel(port)
            println("[OfflineHPC] ✓ Tunnel is active")
        else
            println("[OfflineHPC] ✗ Tunnel not detected. Is serve() running on local machine?")
        end
    end

    return nothing
end

"""
    disconnect()

Remove proxy configuration, restoring original environment.
"""
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
    println("[OfflineHPC] Proxy disconnected")
    return nothing
end

"""
    status()

Check current connection status. Returns :connected or :disconnected.
"""
function status()
    if haskey(ENV, "HTTP_PROXY") && startswith(get(ENV, "HTTP_PROXY", ""), "http://localhost")
        return :connected
    end
    return :disconnected
end

function _check_tunnel(port::Int)
    try
        sock = Sockets.connect(IPv4("127.0.0.1"), port)
        close(sock)
        return true
    catch
        return false
    end
end

# Need Sockets for health check
using Sockets: IPv4

end # module OfflineHPCClient
```

**Step 4: Run test to verify it passes**

Run: `julia --project=. -e "using Pkg; Pkg.test()"`
Expected: PASS

**Step 5: Commit**

```bash
git add scripts/connect.jl test/test_connect.jl
git commit -m "feat: standalone HPC client connect.jl"
```

---

### Task 9: Main Module — Wire Everything Together

**Files:**
- Modify: `src/OfflineHPC.jl`

**Step 1: Write the failing test**

This is an integration wiring test — we already tested components. The test verifies the `serve` function signature exists and `stop` works.

Add to `test/runtests.jl` (before the includes):

```julia
using OfflineHPC

@testset "top-level API" begin
    # serve() without SSH — just proxy mode
    state = OfflineHPC.start_proxy(port=0)
    @test state.running == true
    @test state.port > 0
    OfflineHPC.stop_proxy(state)
    @test state.running == false
end
```

**Step 2: Update main module**

In `src/OfflineHPC.jl`:

```julia
module OfflineHPC

export serve, stop

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
```

**Step 3: Run test to verify it passes**

Run: `julia --project=. -e "using Pkg; Pkg.test()"`
Expected: PASS

**Step 4: Commit**

```bash
git add src/OfflineHPC.jl test/runtests.jl
git commit -m "feat: wire up main module with serve/stop API"
```

---

### Task 10: End-to-End Integration Test

**Files:**
- Modify: `test/runtests.jl`

Full round-trip test: proxy + client env config + HTTP request through proxy.

**Step 1: Write the test**

Add to `test/runtests.jl`:

```julia
@testset "end-to-end: client through proxy" begin
    # Start a mock "internet" HTTP server
    internet = listen(IPv4("127.0.0.1"), 0)
    internet_port = getsockname(internet)[2]
    @async begin
        sock = accept(internet)
        readavailable(sock)  # consume request
        write(sock, "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nhello world")
        close(sock)
    end

    # Start proxy
    state = OfflineHPC.start_proxy(port=0)

    # Simulate what connect.jl does
    ENV["HTTP_PROXY"] = "http://localhost:$(state.port)"

    # Make a request through the proxy (simulating what Julia Pkg would do)
    client = connect(IPv4("127.0.0.1"), state.port)
    write(client, "GET http://127.0.0.1:$(internet_port)/package HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    flush(client)
    sleep(0.5)
    resp = String(readavailable(client))
    @test contains(resp, "hello world")

    close(client)
    OfflineHPC.stop_proxy(state)
    delete!(ENV, "HTTP_PROXY")
    close(internet)
end
```

**Step 2: Run test to verify it passes**

Run: `julia --project=. -e "using Pkg; Pkg.test()"`
Expected: PASS

**Step 3: Commit**

```bash
git add test/runtests.jl
git commit -m "test: end-to-end integration test"
```

---

### Task 11: Final Cleanup and README

**Files:**
- Update: `src/proxy.jl` — add logging toggle
- Create: `README.md` (only because this is a distributable package)

**Step 1: Add a `verbose` flag to proxy**

At the top of `src/proxy.jl`, add:

```julia
const VERBOSE = Ref(false)

function set_verbose(v::Bool)
    VERBOSE[] = v
end

macro proxy_log(msg)
    quote
        VERBOSE[] && println("[proxy] ", $(esc(msg)))
    end
end
```

Then sprinkle `@proxy_log "Handling CONNECT to $target"` in `handle_connect` and `@proxy_log "Forwarding $method $uri"` in `handle_http`.

**Step 2: Write README.md**

```markdown
# OfflineHPC.jl

Install Julia packages on air-gapped HPC systems through an SSH reverse tunnel proxy.

## Quick Start

### Local machine (has internet)

```julia
using OfflineHPC
state = serve("user@hpc.example.com", port=8080)
```

### HPC (no internet)

```julia
include("connect.jl")
OfflineHPCClient.connect(port=8080)

# Now use Pkg normally:
using Pkg
Pkg.add("Example")
```

### Setup

1. Install OfflineHPC.jl on your local machine:
   ```julia
   using Pkg; Pkg.develop(path="path/to/offline_hpc")
   ```

2. Copy `scripts/connect.jl` to your HPC:
   ```bash
   scp scripts/connect.jl user@hpc:~/connect.jl
   ```

## Manual tunnel mode

If you prefer to manage the SSH tunnel yourself:

```julia
# Local: start only the proxy
state = serve(port=8080)
```

Then in another terminal:
```bash
ssh -R 8080:localhost:8080 -N user@hpc
```
```

**Step 3: Run all tests**

Run: `julia --project=. -e "using Pkg; Pkg.test()"`
Expected: All tests PASS.

**Step 4: Commit**

```bash
git add -A
git commit -m "docs: add README and verbose logging"
```

---

## Summary

| Task | What it builds | ~Lines |
|------|---------------|--------|
| 1 | Project scaffold | 30 |
| 2 | Request line/header parsing | 40 |
| 3 | URL/CONNECT target parsing | 40 |
| 4 | Bidirectional relay | 30 |
| 5 | Proxy server (HTTP + CONNECT) | 120 |
| 6 | CONNECT tunnel test | 30 |
| 7 | SSH tunnel manager | 60 |
| 8 | HPC client `connect.jl` | 80 |
| 9 | Main module wiring | 50 |
| 10 | End-to-end integration test | 30 |
| 11 | README + logging | 40 |
| **Total** | | **~550** |
