using Test
using Sockets
using OfflineHPC: parse_request_line, parse_headers, parse_target_url,
                  parse_connect_target, relay!, start_proxy, stop_proxy

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
    @test headers["Proxy-Connection"] == "keep-alive"
end

@testset "parse_target_url" begin
    @test parse_target_url("http://example.com/path") == ("example.com", 80, "/path")
    @test parse_target_url("http://example.com:8443/v1") == ("example.com", 8443, "/v1")
    @test parse_target_url("http://example.com") == ("example.com", 80, "/")
end

@testset "parse_target_url https default port" begin
    @test parse_target_url("https://example.com/path")[2] == 443
    @test parse_target_url("https://example.com:8443/path")[2] == 8443
end

@testset "parse CONNECT target" begin
    @test parse_connect_target("example.com:443") == ("example.com", 443)
    @test parse_connect_target("github.com:22") == ("github.com", 22)
end

@testset "relay!" begin
    # relay! is tested implicitly via the HTTP forwarding and CONNECT tests.
    # Here we verify the function exists and can handle already-closed streams
    # without throwing.
    a = PipeBuffer()
    b = PipeBuffer()
    close(a)
    close(b)
    # Should return without error on two closed streams
    relay!(a, b)
    @test true
end

@testset "proxy server HTTP forwarding" begin
    # Start a mock upstream HTTP server
    upstream = listen(IPv4("127.0.0.1"), 0)
    upstream_port = Int(getsockname(upstream)[2])

    @async begin
        try
            sock = accept(upstream)
            request = String(readavailable(sock))
            write(sock, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")
            flush(sock)
            sleep(0.2)
            close(sock)
        catch e
            e isa Base.IOError || rethrow(e)
        end
    end

    proxy_state = start_proxy(port=0)
    proxy_port = proxy_state.port

    try
        client = Sockets.connect(IPv4("127.0.0.1"), proxy_port)
        write(client, "GET http://127.0.0.1:$(upstream_port)/test HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        flush(client)
        sleep(1.5)
        response = String(readavailable(client))
        @test contains(response, "200 OK")
        @test contains(response, "hello")
        close(client)
    finally
        stop_proxy(proxy_state)
        close(upstream)
    end
end

@testset "proxy server CONNECT tunnelling" begin
    # Start a mock upstream TCP server
    upstream = listen(IPv4("127.0.0.1"), 0)
    upstream_port = Int(getsockname(upstream)[2])

    @async begin
        try
            sock = accept(upstream)
            data = String(readavailable(sock))
            write(sock, "PONG:$data")
            flush(sock)
            sleep(0.2)
            close(sock)
        catch e
            e isa Base.IOError || rethrow(e)
        end
    end

    proxy_state = start_proxy(port=0)
    proxy_port = proxy_state.port

    try
        client = Sockets.connect(IPv4("127.0.0.1"), proxy_port)
        write(client, "CONNECT 127.0.0.1:$(upstream_port) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        flush(client)
        sleep(0.5)

        established = String(readavailable(client))
        @test contains(established, "200 Connection Established")

        write(client, "PING")
        flush(client)
        sleep(0.5)
        reply = String(readavailable(client))
        @test contains(reply, "PONG:PING")

        close(client)
    finally
        stop_proxy(proxy_state)
        close(upstream)
    end
end

@testset "CONNECT tunnel reverses data" begin
    # Mock server that reverses whatever it receives
    mock = listen(IPv4("127.0.0.1"), 0)
    mock_port = Int(getsockname(mock)[2])

    @async begin
        try
            sock = accept(mock)
            data = String(readavailable(sock))
            write(sock, reverse(data))
            flush(sock)
            sleep(0.2)
            close(sock)
        catch e
            e isa Base.IOError || rethrow(e)
        end
    end

    proxy_state = start_proxy(port=0)
    proxy_port = proxy_state.port

    try
        client = Sockets.connect(IPv4("127.0.0.1"), proxy_port)
        write(client, "CONNECT 127.0.0.1:$(mock_port) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        flush(client)
        sleep(0.5)

        response = String(readavailable(client))
        @test contains(response, "200")

        write(client, "test data")
        flush(client)
        sleep(0.5)
        reply = String(readavailable(client))
        @test contains(reply, "atad tset")

        close(client)
    finally
        stop_proxy(proxy_state)
        close(mock)
    end
end
