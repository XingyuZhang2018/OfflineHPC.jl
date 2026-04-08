# OfflineHPC.jl — 离线超算 Julia 包安装透明代理

**Date**: 2026-04-08
**Status**: Approved

## Problem

在完全隔离（无外网）的超算上安装 Julia 包极其麻烦。用户只能通过本地 SSH 连入超算，但超算无法访问互联网下载包。

## Solution

一个纯 Julia 包 `OfflineHPC.jl`，通过 SSH 反向端口转发 + 本地 HTTP 代理，让超算上的 `Pkg.add()` 透明地通过本地机器联网下载。

## Architecture

```
┌──────────────────────────┐       SSH -R 8080:localhost:8080       ┌─────────────────────────┐
│   本地 (Windows/Mac/Lin) │ ◄────────────────────────────────────► │   超算 (Linux)           │
│                          │                                        │                         │
│  julia> using OfflineHPC │       反向隧道                          │  include("connect.jl")  │
│  julia> serve("user@hpc")│                                        │  OfflineHPCClient.connect()│
│                          │                                        │  Pkg.add("Foo") # works!│
│  HTTP proxy (Sockets.jl) │                                        │                         │
└──────────────────────────┘                                        └─────────────────────────┘
```

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Language | Pure Julia | Target audience is Julia users on HPC |
| Dependencies | Zero external deps | Both sides use only Julia stdlib (`Sockets`, `Base`) |
| Proxy type | HTTP forward proxy with CONNECT | HTTP_PROXY is well-supported by Julia; CONNECT enables HTTPS tunneling |
| Tunnel | SSH reverse port forwarding (`-R`) | SSH is universally available on HPC |
| HPC deployment | Single file `connect.jl` | Zero bootstrap problem — just scp one file |
| Local deployment | Full Julia package | Local machine has internet, can install normally |

## Components

### 1. Local HTTP Proxy Server (`server.jl`)

- Pure `Sockets.jl` implementation, ~100-150 lines
- Handles HTTP requests: parse request, forward to target, return response
- Handles HTTPS CONNECT: establish tunnel, bidirectional data relay
- Runs on configurable port (default 8080)

### 2. SSH Tunnel Manager (`tunnel.jl`)

- Calls system `ssh` command with `-R port:localhost:port -N`
- Windows: uses OpenSSH (built-in Win10+) or PuTTY plink
- Monitors tunnel process health

### 3. HPC Client (`connect.jl` — standalone single file)

- Zero dependencies, pure stdlib
- Sets environment variables:
  - `HTTP_PROXY` / `HTTPS_PROXY` → `http://localhost:PORT`
  - `JULIA_PKG_USE_CLI_GIT=true` (bypass libgit2 proxy issues)
  - `JULIA_PKG_SERVER=""` (disable PkgServer protocol, force git)
- Health check via curl or socket connect
- `disconnect()` to restore original state

### 4. One-command launcher

```julia
# Local machine
using OfflineHPC
serve("user@hpc.example.com", port=8080)
# Starts proxy + SSH tunnel in one call
```

## Usage Flow

1. First time: `scp connect.jl user@hpc:/path/to/connect.jl`
2. Local: `julia -e 'using OfflineHPC; serve("user@hpc")'`
3. HPC: `include("connect.jl"); OfflineHPCClient.connect(); Pkg.add("Foo")`

## Error Handling

- Tunnel disconnect → proxy timeout → Pkg network error → user restarts `serve()`
- Port conflict → detect on startup, suggest alternative
- SSH auth failure → capture exit code, display message

## Constraints

- HPC SSH must allow reverse port forwarding (most do by default)
- Julia must be installed on both local and HPC
- System `ssh` binary must be available on local machine
