require "./spec_helper"

describe "CML UDP socket events" do
  it "can send and receive datagrams" do
    server = UDPSocket.new
    begin
      server.bind("127.0.0.1", 0)
    rescue ex : Socket::BindError
      pending!("cannot bind UDP socket: #{ex.message}")
    end

    port = server.local_address.port
    client = UDPSocket.new

    received = Atomic(Bool).new(false)

    ::spawn do
      data, addr = CML.sync(CML::Socket::UDP.recv_evt(server, 64))
      addr = addr.as(Socket::IPAddress)
      received.set(String.new(data) == "ping")
      CML.sync(CML::Socket::UDP.send_evt(server, "pong".to_slice, addr.address, addr.port))
    end

    CML.sync(CML::Socket::UDP.send_evt(client, "ping".to_slice, "127.0.0.1", port))
    data_addr = CML.sync(CML::Socket::UDP.recv_evt(client, 64))
    data = data_addr[0]

    String.new(data).should eq("pong")
    received.get.should be_true

    client.close
    server.close
  end
end
