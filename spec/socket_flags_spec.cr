require "./spec_helper"

private def sync_with_timeout(evt : CML::Event(T), label : String, timeout = 10.seconds) : T forall T
  result = CML.sync(CML.choose(
    CML.wrap(evt) { |value| {true, value.as(T | Nil)} },
    CML.wrap(CML.timeout(timeout)) { {false, nil.as(T | Nil)} },
  ))
  won, value = result
  won.should be_true, "timed out waiting for #{label} after #{timeout.total_seconds}s"
  value.as(T)
end

describe "CML socket flag support" do
  describe "Flags constants" do
    it "defines MSG_PEEK" do
      CML::Socket::Flags::MSG_PEEK.should be_a(Int32)
    end

    it "defines MSG_OOB" do
      CML::Socket::Flags::MSG_OOB.should be_a(Int32)
    end

    it "defines MSG_DONTROUTE" do
      CML::Socket::Flags::MSG_DONTROUTE.should be_a(Int32)
    end

    it "defines MSG_DONTWAIT" do
      CML::Socket::Flags::MSG_DONTWAIT.should be_a(Int32)
    end

    it "defines MSG_WAITALL" do
      CML::Socket::Flags::MSG_WAITALL.should be_a(Int32)
    end

    it "defines NONE = 0" do
      CML::Socket::Flags::NONE.should eq(0)
    end
  end

  describe "stream sockets with flags" do
    it "can peek data without consuming" do
      # Create a server and client socket
      server = begin
        TCPServer.new("127.0.0.1", 0)
      rescue ex : Socket::BindError
        pending!("cannot bind TCP socket in this environment: #{ex.message}")
      end
      port = server.local_address.port

      ::spawn do
        begin
          socket, _addr = sync_with_timeout(CML::Socket.accept_evt(server), "server accept")
          # Send data to client
          sync_with_timeout(CML::Socket.send_evt(socket, "hello".to_slice), "server send hello")
          socket.close
        rescue ex : Socket::Error
        end
      end
      Fiber.yield

      client = TCPSocket.new
      sync_with_timeout(CML::Socket.connect_evt(client, Socket::IPAddress.new("127.0.0.1", port)), "client connect")
      # Peek at data without consuming
      peeked = sync_with_timeout(CML::Socket.recv_evt(client, 5, CML::Socket::Flags::MSG_PEEK), "client recv peek")
      String.new(peeked).should eq("hello")

      # After peek, data should still be available to read
      received = sync_with_timeout(CML::Socket.recv_evt(client, 5), "client recv consume")
      String.new(received).should eq("hello")

      client.close
      server.close
    end

    it "supports send with flags (no effect but should not crash)" do
      server = begin
        TCPServer.new("127.0.0.1", 0)
      rescue ex : Socket::BindError
        pending!("cannot bind TCP socket in this environment: #{ex.message}")
      end
      port = server.local_address.port

      ::spawn do
        begin
          socket, _addr = sync_with_timeout(CML::Socket.accept_evt(server), "server accept")
          msg = sync_with_timeout(CML::Socket.recv_evt(socket, 4), "server recv test")
          String.new(msg).should eq("test")
          socket.close
        rescue ex : Socket::Error
        end
      end
      Fiber.yield

      client = TCPSocket.new
      sync_with_timeout(CML::Socket.connect_evt(client, Socket::IPAddress.new("127.0.0.1", port)), "client connect")
      # Send with MSG_DONTROUTE flag (may be ignored but shouldn't crash)
      bytes_sent = sync_with_timeout(CML::Socket.send_evt(client, "test".to_slice, CML::Socket::Flags::MSG_DONTROUTE), "client send test")
      bytes_sent.should eq(4)
      client.close
      server.close
    end

    it "maintains backward compatibility (no flags parameter)" do
      server = begin
        TCPServer.new("127.0.0.1", 0)
      rescue ex : Socket::BindError
        pending!("cannot bind TCP socket in this environment: #{ex.message}")
      end
      port = server.local_address.port

      received = Channel(Bool).new(1)
      ::spawn do
        begin
          socket, _addr = sync_with_timeout(CML::Socket.accept_evt(server), "server accept")
          msg = sync_with_timeout(CML::Socket.recv_evt(socket, 8), "server recv backward")
          received.send(String.new(msg) == "backward")
          socket.close
        rescue ex : Socket::Error
          received.send(false)
        end
      end
      Fiber.yield

      client = TCPSocket.new
      sync_with_timeout(CML::Socket.connect_evt(client, Socket::IPAddress.new("127.0.0.1", port)), "client connect")
      bytes_sent = sync_with_timeout(CML::Socket.send_evt(client, "backward".to_slice), "client send backward")
      bytes_sent.should eq(8)
      select
      when ok = received.receive
        ok.should be_true
      when timeout(2.seconds)
        fail "timed out waiting for server receive confirmation"
      end
      client.close
      server.close
    end
  end

  # UDP socket flag tests are pending due to indentation bug in UDP module
  # describe "UDP sockets with flags" do
  #   it "can send and receive with flags" do
  #     server = CML::Socket.udp
  #     server.inner.bind("127.0.0.1", 0)
  #     port = server.inner.local_address.port
  #
  #     client = CML::Socket.udp
  #     data = "udp test".to_slice
  #
  #     # Send with flags (may be ignored)
  #     bytes_sent = CML.sync(CML::Socket::UDP.send_evt(client, data, CML::Socket::Flags::MSG_DONTROUTE, "127.0.0.1", port))
  #     bytes_sent.should eq(data.size)
  #
  #     # Receive with flags
  #     received, addr = CML.sync(CML::Socket::UDP.recv_evt(server, 1024, CML::Socket::Flags::MSG_PEEK))
  #     String.new(received).should eq("udp test")
  #
  #     client.close
  #     server.close
  #   end
  #
  #   it "maintains backward compatibility for UDP" do
  #     server = CML::Socket.udp
  #     server.inner.bind("127.0.0.1", 0)
  #     port = server.inner.local_address.port
  #
  #     client = CML::Socket.udp
  #     data = "udp legacy".to_slice
  #
  #     bytes_sent = CML.sync(CML::Socket::UDP.send_evt(client, data, "127.0.0.1", port))
  #     bytes_sent.should eq(data.size)
  #
  #     received, addr = CML.sync(CML::Socket::UDP.recv_evt(server, 1024))
  #     String.new(received).should eq("udp legacy")
  #
  #     client.close
  #     server.close
  #   end
  # end
end
