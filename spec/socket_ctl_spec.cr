require "./spec_helper"

describe "CML::Socket::Ctl" do
  describe ".get_reuse_addr / .set_reuse_addr" do
    it "gets and sets SO_REUSEADDR option" do
      socket = CML::Socket.tcp
      original = CML::Socket::Ctl.get_reuse_addr(socket)
      # Set opposite value
      CML::Socket::Ctl.set_reuse_addr(socket, !original)
      new_value = CML::Socket::Ctl.get_reuse_addr(socket)
      new_value.should eq(!original)
      # Restore original
      CML::Socket::Ctl.set_reuse_addr(socket, original)
      socket.close
    end
  end

  describe ".get_keepalive / .set_keepalive" do
    it "gets and sets SO_KEEPALIVE option" do
      socket = CML::Socket.tcp
      original = CML::Socket::Ctl.get_keepalive(socket)
      CML::Socket::Ctl.set_keepalive(socket, !original)
      new_value = CML::Socket::Ctl.get_keepalive(socket)
      new_value.should eq(!original)
      CML::Socket::Ctl.set_keepalive(socket, original)
      socket.close
    end
  end

  describe ".get_dont_route / .set_dont_route" do
    it "calls methods without crashing (SO_DONTROUTE not implemented in Crystal)" do
      socket = CML::Socket.tcp
      # Should return false (stub)
      value = CML::Socket::Ctl.get_dont_route(socket)
      value.should be_false
      # Setting should not crash
      CML::Socket::Ctl.set_dont_route(socket, true)
      CML::Socket::Ctl.set_dont_route(socket, false)
      socket.close
    end
  end

  describe ".get_broadcast / .set_broadcast" do
    it "gets and sets SO_BROADCAST option" do
      socket = CML::Socket.udp
      original = CML::Socket::Ctl.get_broadcast(socket)
      CML::Socket::Ctl.set_broadcast(socket, !original)
      new_value = CML::Socket::Ctl.get_broadcast(socket)
      new_value.should eq(!original)
      CML::Socket::Ctl.set_broadcast(socket, original)
      socket.close
    end
  end

  describe ".get_oob_inline / .set_oob_inline" do
    it "calls methods without crashing (SO_OOBINLINE not implemented in Crystal)" do
      socket = CML::Socket.tcp
      value = CML::Socket::Ctl.get_oob_inline(socket)
      value.should be_false
      CML::Socket::Ctl.set_oob_inline(socket, true)
      CML::Socket::Ctl.set_oob_inline(socket, false)
      socket.close
    end
  end

  describe ".get_snd_buf / .set_snd_buf" do
    it "gets and sets SO_SNDBUF option" do
      socket = CML::Socket.tcp
      original = CML::Socket::Ctl.get_snd_buf(socket)
      # Try to set a different value (increase by 1024)
      new_size = original + 1024
      CML::Socket::Ctl.set_snd_buf(socket, new_size)
      # Note: kernel may round the value, so we just check it changed
      changed = CML::Socket::Ctl.get_snd_buf(socket)
      changed.should_not eq(original)
      socket.close
    end
  end

  describe ".get_rcv_buf / .set_rcv_buf" do
    it "gets and sets SO_RCVBUF option" do
      socket = CML::Socket.tcp
      original = CML::Socket::Ctl.get_rcv_buf(socket)
      new_size = original + 1024
      CML::Socket::Ctl.set_rcv_buf(socket, new_size)
      changed = CML::Socket::Ctl.get_rcv_buf(socket)
      changed.should_not eq(original)
      socket.close
    end
  end

  describe ".get_linger / .set_linger" do
    it "gets and sets SO_LINGER option" do
      socket = CML::Socket.tcp
      linger = CML::Socket::Ctl.get_linger(socket)
      # May be nil (linger not set)
      if linger.nil?
        # Set linger
        CML::Socket::Ctl.set_linger(socket, true, 5)
        new_linger = CML::Socket::Ctl.get_linger(socket)
        new_linger.should eq({true, 5})
        # Disable linger
        CML::Socket::Ctl.set_linger(socket, false, 0)
        disabled = CML::Socket::Ctl.get_linger(socket)
        disabled.should eq({false, 0})
      else
        # Toggle enabled
        enabled, seconds = linger
        CML::Socket::Ctl.set_linger(socket, !enabled, seconds)
        toggled = CML::Socket::Ctl.get_linger(socket)
        toggled.should eq({!enabled, seconds})
        # Restore
        CML::Socket::Ctl.set_linger(socket, enabled, seconds)
      end
      socket.close
    end
  end

  describe ".get_type" do
    it "returns socket type" do
      tcp = CML::Socket.tcp
      CML::Socket::Ctl.get_type(tcp).should eq(::Socket::Type::STREAM)
      tcp.close

      udp = CML::Socket.udp
      CML::Socket::Ctl.get_type(udp).should eq(::Socket::Type::DGRAM)
      udp.close
    end
  end

  describe ".get_peer_name / .get_sock_name" do
    it "gets socket addresses for connected sockets" do
      # Create a socket pair to have connected sockets
      left, right = CML::Socket.socket_pair(:inet, :stream)
      begin
        # Both sockets are connected to each other
        peer = CML::Socket::Ctl.get_peer_name(left)
        sock = CML::Socket::Ctl.get_sock_name(left)
        peer.should be_a(::Socket::IPAddress)
        sock.should be_a(::Socket::IPAddress)
        # They should have different ports
        peer.as(::Socket::IPAddress).port.should_not eq(sock.as(::Socket::IPAddress).port)
      ensure
        left.close
        right.close
      end
    end
  end

  describe ".get_error" do
    it "returns socket error (should be 0 for new socket)" do
      socket = CML::Socket.tcp
      CML::Socket::Ctl.get_error(socket).should eq(0)
      socket.close
    end
  end

  describe ".get_nread" do
    it "returns nil (not implemented)" do
      socket = CML::Socket.tcp
      CML::Socket::Ctl.get_nread(socket).should be_nil
      socket.close
    end
  end

  describe ".get_at_mark" do
    it "returns false (not implemented)" do
      socket = CML::Socket.tcp
      CML::Socket::Ctl.get_at_mark(socket).should be_false
      socket.close
    end
  end

  describe "works with raw sockets" do
    it "accepts raw ::Socket objects" do
      raw = ::TCPSocket.new
      CML::Socket::Ctl.get_reuse_addr(raw).should be_a(Bool)
      raw.close
    end
  end
end
