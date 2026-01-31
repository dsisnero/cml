require "./spec_helper"

describe "CML Unix socket events" do

  it "accepts Unix stream connections and exchanges data" do
    # Create a temporary socket path
    socket_path = File.tempname("cml_unix_socket")
    begin
      server = begin
        UNIXServer.new(socket_path)
      rescue ex : Socket::BindError
        pending!("cannot bind Unix socket in this environment: #{ex.message}")
      end

      received = Atomic(Bool).new(false)

      ::spawn do
        socket = CML.sync(CML::Socket.accept_evt(server))
        msg = CML.sync(CML::Socket.recv_evt(socket, 5))
        received.set(String.new(msg) == "ping\n")
        CML.sync(CML::Socket.send_evt(socket, "pong\n".to_slice))
        socket.close
      end

      client = CML.sync(CML::Socket.unix_connect_evt(socket_path))
      CML.sync(CML::Socket.send_evt(client, "ping\n".to_slice))
      data = CML.sync(CML::Socket.recv_evt(client, 5))

      String.new(data).should eq("pong\n")
      received.get.should be_true

      client.close
      server.close
    ensure
      # Clean up socket file
      File.delete?(socket_path)
    end
  end

  it "works with Unix wrapper factories" do
    socket_path = File.tempname("cml_unix_wrapper")
    begin
      # Create server using wrapper factory
      server = CML::Socket.unix_server(socket_path)
      server.should be_a(CML::Socket::UnixPassiveSocket)

      received = Atomic(Bool).new(false)

      ::spawn do
        # Use accept_evt with wrapper
        socket = CML.sync(CML::Socket.accept_evt(server))
        socket.should be_a(::UNIXSocket)
        msg = CML.sync(CML::Socket.recv_evt(socket, 5))
        received.set(String.new(msg) == "test\n")
        socket.close
      end

      # Create client using wrapper factory
      client = CML::Socket.unix_stream
      client.should be_a(CML::Socket::UnixStreamSocket)
      # Connect using underlying socket
      client.inner.connect(Socket::UNIXAddress.new(socket_path))

      CML.sync(CML::Socket.send_evt(client, "test\n".to_slice))
      received.get.should be_true

      client.close
      server.close
    ensure
      File.delete?(socket_path)
    end
  end

  it "can race Unix accept with a timeout" do
    socket_path = File.tempname("cml_unix_race")
    begin
      server = begin
        UNIXServer.new(socket_path)
      rescue ex : Socket::BindError
        pending!("cannot bind Unix socket in this environment: #{ex.message}")
      end

      result = CML.sync(CML.choose([
        CML.wrap(CML::Socket.accept_evt(server)) { :accepted },
        CML.wrap(CML.timeout(50.milliseconds)) { :timeout },
      ]))

      result.should eq(:timeout)
      server.close
    ensure
      File.delete?(socket_path)
    end
  end

  it "works with Unix datagram sockets" do
    server_path = File.tempname("cml_unix_dgram_server")
    client_path = File.tempname("cml_unix_dgram_client")
    begin
      # Create Unix datagram socket using wrapper
      server = CML::Socket.unix_dgram
      server.should be_a(CML::Socket::UnixDatagramSocket)
      server.inner.bind(Socket::UNIXAddress.new(server_path))

      client = CML::Socket.unix_dgram
      client.should be_a(CML::Socket::UnixDatagramSocket)
      client.inner.bind(Socket::UNIXAddress.new(client_path))
      client.inner.connect(Socket::UNIXAddress.new(server_path))

      # Send data from client to server
      data = "test".to_slice
      bytes_sent = CML.sync(CML::Socket.send_evt(client, data))
      bytes_sent.should eq(data.size)

      # Receive on server
      received = CML.sync(CML::Socket.recv_evt(server, 1024))
      String.new(received).should eq("test")

      server.close
      client.close
    ensure
      File.delete?(server_path)
      File.delete?(client_path)
    end
  end

  it "handles Unix socket errors gracefully" do
    # Try to connect to non-existent socket
    socket_path = File.tempname("cml_unix_nonexist")
    # Ensure file doesn't exist
    File.delete?(socket_path)

    # Should raise error (connection refused)
    expect_raises(IO::Error) do
      CML.sync(CML::Socket.unix_connect_evt(socket_path))
    end
  end
end