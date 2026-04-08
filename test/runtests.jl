using Test
using OfflineHPC
using Sockets

@testset "top-level API" begin
    state = OfflineHPC.start_proxy(port=0)
    @test state.running[] == true
    @test state.port > 0
    OfflineHPC.stop_proxy(state)
    @test state.running[] == false
end

@testset "end-to-end: client through proxy" begin
    # Start a mock "internet" HTTP server
    internet = listen(IPv4("127.0.0.1"), 0)
    internet_port = getsockname(internet)[2]
    @async begin
        sock = accept(internet)
        readavailable(sock)
        write(sock, "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nhello world")
        flush(sock)
        sleep(0.2)
        close(sock)
    end

    state = OfflineHPC.start_proxy(port=0)
    ENV["HTTP_PROXY"] = "http://localhost:$(state.port)"

    client = Sockets.connect(IPv4("127.0.0.1"), state.port)
    write(client, "GET http://127.0.0.1:$(internet_port)/package HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    flush(client)
    sleep(1.5)
    resp = String(readavailable(client))
    @test contains(resp, "hello world")

    close(client)
    OfflineHPC.stop_proxy(state)
    delete!(ENV, "HTTP_PROXY")
    close(internet)
end

@testset "OfflineHPC.jl" begin
    include("test_proxy.jl")
    include("test_connect.jl")
    include("test_tunnel.jl")
end
