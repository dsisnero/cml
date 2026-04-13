require "./spec_helper"

private def sync_evt_with_timeout(evt : CML::Event(T), label : String, timeout = 5.seconds) : T forall T
  result = CML.select(evt, CML.timeout(timeout))
  result.should_not be_nil, "timed out waiting for #{label} after #{timeout.total_seconds}s"
  result.as(T)
end

describe "CML socket wrapper factory" do
  describe ".tcp" do
    it "creates a TCP stream socket wrapper" do
      socket = CML::Socket.tcp
      socket.should be_a(CML::Socket::StreamSocket)
      socket.inner.should be_a(::TCPSocket)
      socket.closed?.should be_false
      socket.close
      socket.closed?.should be_true
    end
  end

  describe ".udp" do
    it "creates a UDP datagram socket wrapper" do
      socket = CML::Socket.udp
      socket.should be_a(CML::Socket::DatagramSocket)
      socket.inner.should be_a(::UDPSocket)
      socket.closed?.should be_false
      socket.close
      socket.closed?.should be_true
    end
  end

  describe ".tcp_server" do
    it "creates a TCP passive socket wrapper" do
      server = begin
        CML::Socket.tcp_server("127.0.0.1", 0)
      rescue ex : Socket::BindError
        pending!("cannot bind TCP socket in this environment: #{ex.message}")
      end
      server.should be_a(CML::Socket::PassiveSocket)
      server.inner.should be_a(::TCPServer)
      server.closed?.should be_false
      server.close
      server.closed?.should be_true
    end
  end

  describe ".socket" do
    it "creates INET stream socket" do
      wrapper = CML::Socket.socket(:inet, :stream)
      wrapper.should be_a(CML::Socket::SocketWrapper)
      wrapper.inner.should be_a(::Socket)
      wrapper.close
    end

    it "creates INET datagram socket" do
      wrapper = CML::Socket.socket(:inet, :dgram)
      wrapper.should be_a(CML::Socket::SocketWrapper)
      wrapper.inner.should be_a(::Socket)
      wrapper.close
    end

    it "raises for unsupported family/type" do
      expect_raises(ArgumentError) { CML::Socket.socket(:foo, :stream) }
      expect_raises(ArgumentError) { CML::Socket.socket(:inet, :foo) }
    end
  end

  describe ".socket_pair" do
    it "creates a pair of connected INET stream sockets" do
      left, right = begin
        CML::Socket.socket_pair(:inet, :stream)
      rescue ex : Socket::BindError
        pending!("cannot bind socket pair in this environment: #{ex.message}")
      end
      left.should be_a(CML::Socket::SocketWrapper)
      right.should be_a(CML::Socket::SocketWrapper)
      # They should be connected (can send data)
      # For now just check they're not closed
      left.closed?.should be_false
      right.closed?.should be_false
      left.close
      right.close
    end

    it "creates a pair of connected INET datagram sockets" do
      left, right = begin
        CML::Socket.socket_pair(:inet, :dgram)
      rescue ex : Socket::BindError
        pending!("cannot bind datagram socket pair in this environment: #{ex.message}")
      end
      left.should be_a(CML::Socket::SocketWrapper)
      right.should be_a(CML::Socket::SocketWrapper)
      left.closed?.should be_false
      right.closed?.should be_false
      left.close
      right.close
    end
  end

  describe ".socket_with_protocol" do
    it "creates socket with specified protocol" do
      # Just test it doesn't crash
      wrapper = CML::Socket.socket_with_protocol(:inet, :stream, 0)
      wrapper.should be_a(CML::Socket::SocketWrapper)
      wrapper.close
    end
  end

  describe ".socket_pair_with_protocol" do
    it "creates socket pair with specified protocol" do
      pair_ch = Channel({CML::Socket::SocketWrapper, CML::Socket::SocketWrapper} | Exception).new(1)
      spawn do
        begin
          left, right = CML::Socket.socket_pair_with_protocol(:inet, :stream, 0)
          pair_ch.send({left, right})
        rescue ex
          pair_ch.send(ex)
        end
      end

      pair = select
             when result = pair_ch.receive
               result
             when timeout(5.seconds)
               fail "timed out creating socket pair with specified protocol"
               raise "unreachable"
             end

      case pair
      when Tuple(CML::Socket::SocketWrapper, CML::Socket::SocketWrapper)
        left, right = pair
        left.should be_a(CML::Socket::SocketWrapper)
        right.should be_a(CML::Socket::SocketWrapper)
        left.close
        right.close
      when Socket::BindError
        pending!("cannot bind socket pair in this environment: #{pair.message}")
      when Exception
        raise pair
      end
    end
  end

  describe "wrapper event integration" do
    it "works with accept_evt" do
      server = begin
        CML::Socket.tcp_server("127.0.0.1", 0)
      rescue ex : Socket::BindError
        pending!("cannot bind TCP socket in this environment: #{ex.message}")
      end
      port = server.inner.local_address.port

      ::spawn do
        client = TCPSocket.new("127.0.0.1", port)
        client.close
      end

      # This should work because accept_evt has overload for PassiveSocket
      event = CML::Socket.accept_evt(server)
      socket, _addr = sync_evt_with_timeout(event, "accept_evt")
      socket.should be_a(::TCPSocket)
      socket.close
      server.close
    end

    it "works with recv_evt and send_evt for stream sockets" do
      # Create a pair of connected sockets using socket_pair
      left, right = begin
        CML::Socket.socket_pair(:inet, :stream)
      rescue ex : Socket::BindError
        pending!("cannot bind socket pair in this environment: #{ex.message}")
      end
      # Ensure they are wrapped as StreamSocket
      # Send data from left to right
      data = "hello".to_slice
      send_event = CML::Socket.send_evt(left.as(CML::Socket::StreamSocket), data)
      bytes_sent = sync_evt_with_timeout(send_event, "stream send_evt")
      bytes_sent.should eq(data.size)

      recv_event = CML::Socket.recv_evt(right.as(CML::Socket::StreamSocket), 5)
      received = sync_evt_with_timeout(recv_event, "stream recv_evt")
      String.new(received).should eq("hello")

      left.close
      right.close
    end

    it "works with UDP send_evt and recv_evt" do
      server = CML::Socket.udp
      begin
        server.inner.bind("127.0.0.1", 0)
      rescue ex : Socket::BindError
        pending!("cannot bind UDP socket in this environment: #{ex.message}")
      end
      port = server.inner.local_address.port

      client = CML::Socket.udp
      data = "test".to_slice

      send_event = CML::Socket::UDP.send_evt(client, data, "127.0.0.1", port)
      bytes_sent = sync_evt_with_timeout(send_event, "udp send_evt")
      bytes_sent.should eq(data.size)

      recv_event = CML::Socket::UDP.recv_evt(server, 1024)
      received, _ = sync_evt_with_timeout(recv_event, "udp recv_evt")
      String.new(received).should eq("test")

      client.close
      server.close
    end

    it "supports vec/arr aliases for connected datagram sockets" do
      left, right = begin
        CML::Socket.socket_pair(:inet, :dgram)
      rescue ex : Socket::BindError
        pending!("cannot bind datagram socket pair in this environment: #{ex.message}")
      end
      left = left.as(CML::Socket::DatagramSocket)
      right = right.as(CML::Socket::DatagramSocket)

      data = "ping".to_slice
      bytes_sent = CML.select(CML::Socket::UDP.send_vec_evt(left, data), CML.timeout(2.seconds))
      bytes_sent.should_not be_nil
      bytes_sent = bytes_sent.as(Int32)
      bytes_sent.should eq(data.size)

      received = CML.select(CML::Socket::UDP.recv_vec_evt(right, data.size), CML.timeout(2.seconds))
      received.should_not be_nil
      received = received.as(Bytes)
      String.new(received).should eq("ping")

      buffer = Bytes.new(4)
      bytes_sent = CML.select(CML::Socket::UDP.send_vec_evt(left, data), CML.timeout(2.seconds))
      bytes_sent.should_not be_nil
      bytes_sent = bytes_sent.as(Int32)
      bytes_sent.should eq(data.size)

      bytes_read = CML.select(CML::Socket::UDP.recv_arr_evt(right, buffer), CML.timeout(2.seconds))
      bytes_read.should_not be_nil
      bytes_read = bytes_read.as(Int32)
      bytes_read.should eq(4)
      String.new(buffer).should eq("ping")

      left.close
      right.close
    end
  end
end
