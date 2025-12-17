require "./spec_helper"

describe "CML socket events" do
  it "accepts and exchanges data" do
    server = begin
      TCPServer.new("127.0.0.1", 0)
    rescue ex : Socket::BindError
      pending!("cannot bind TCP socket in this environment: #{ex.message}")
    end
    port = server.local_address.port
    received = Atomic(Bool).new(false)

    ::spawn do
      socket = CML.sync(CML::Socket.accept_evt(server))
      msg = CML.sync(CML::Socket.recv_evt(socket, 5))
      received.set(String.new(msg) == "ping\n")
      CML.sync(CML::Socket.send_evt(socket, "pong\n".to_slice))
      socket.close
    end

    client = CML.sync(CML::Socket.connect_evt("127.0.0.1", port))
    CML.sync(CML::Socket.send_evt(client, "ping\n".to_slice))
    data = CML.sync(CML::Socket.recv_evt(client, 5))

    String.new(data).should eq("pong\n")
    received.get.should be_true

    client.close
    server.close
  end

  it "can race accept with a timeout" do
    server = begin
      TCPServer.new("127.0.0.1", 0)
    rescue ex : Socket::BindError
      pending!("cannot bind TCP socket in this environment: #{ex.message}")
    end

    result = CML.sync(CML.choose([
      CML.wrap(CML::Socket.accept_evt(server)) { :accepted },
      CML.wrap(CML.timeout(50.milliseconds)) { :timeout },
    ]))

    result.should eq(:timeout)
    server.close
  end
end
