require "./spec_helper"

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
      server = CML::Socket.tcp_server("127.0.0.1", 0)
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
      left, right = CML::Socket.socket_pair(:inet, :stream)
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
      left, right = CML::Socket.socket_pair(:inet, :dgram)
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
      left, right = CML::Socket.socket_pair_with_protocol(:inet, :stream, 0)
      left.should be_a(CML::Socket::SocketWrapper)
      right.should be_a(CML::Socket::SocketWrapper)
      left.close
      right.close
    end
  end

  describe "wrapper event integration" do
    it "works with accept_evt" do
      server = CML::Socket.tcp_server("127.0.0.1", 0)
      port = server.inner.local_address.port

      ::spawn do
        client = TCPSocket.new("127.0.0.1", port)
        client.close
      end

      # This should work because accept_evt has overload for PassiveSocket
      event = CML::Socket.accept_evt(server)
      socket = CML.sync(event)
      socket.should be_a(::TCPSocket)
      socket.close
      server.close
    end

    it "works with recv_evt and send_evt for stream sockets" do
      # Create a pair of connected sockets using socket_pair
      left, right = CML::Socket.socket_pair(:inet, :stream)
      # Ensure they are wrapped as StreamSocket
      # Send data from left to right
      data = "hello".to_slice
      send_event = CML::Socket.send_evt(left.as(CML::Socket::StreamSocket), data)
      bytes_sent = CML.sync(send_event)
      bytes_sent.should eq(data.size)

      recv_event = CML::Socket.recv_evt(right.as(CML::Socket::StreamSocket), 5)
      received = CML.sync(recv_event)
      String.new(received).should eq("hello")

      left.close
      right.close
    end

    it "works with UDP send_evt and recv_evt" do
      server = CML::Socket.udp
      server.inner.bind("127.0.0.1", 0)
      port = server.inner.local_address.port

      client = CML::Socket.udp
      data = "test".to_slice

      send_event = CML::Socket::UDP.send_evt(client, data, "127.0.0.1", port)
      bytes_sent = CML.sync(send_event)
      bytes_sent.should eq(data.size)

      recv_event = CML::Socket::UDP.recv_evt(server, 1024)
      received, addr = CML.sync(recv_event)
      String.new(received).should eq("test")

      client.close
      server.close
    end
  end
end
