require "socket"
require "./socket_wrapper"

module CML
  module Socket
    # Socket control operations matching SML/NJ CML_SOCKET Ctl structure.
    module Ctl
      # Gets the SO_REUSEADDR option.
      def self.get_reuse_addr(socket : ::Socket) : Bool
        socket.reuse_address?
      end

      # Sets the SO_REUSEADDR option.
      def self.set_reuse_addr(socket : ::Socket, value : Bool) : Nil
        socket.reuse_address = value
      end

      # Gets the SO_KEEPALIVE option.
      def self.get_keepalive(socket : ::Socket) : Bool
        socket.keepalive?
      end

      # Sets the SO_KEEPALIVE option.
      def self.set_keepalive(socket : ::Socket, value : Bool) : Nil
        socket.keepalive = value
      end

      # Gets the SO_DONTROUTE option.
      # Not implemented in Crystal's standard library; returns false.
      def self.get_dont_route(socket : ::Socket) : Bool
        false
      end

      # Sets the SO_DONTROUTE option.
      # Not implemented in Crystal's standard library; no-op.
      def self.set_dont_route(socket : ::Socket, value : Bool) : Nil
        # no-op
      end

      # Gets the SO_LINGER option.
      # Returns linger enabled (seconds > 0) and linger time in seconds.
      # Returns nil if linger not set.
      def self.get_linger(socket : ::Socket) : {Bool, Int32}?
        socket.linger.try do |seconds|
          {seconds > 0, seconds}
        end
      end

      # Sets the SO_LINGER option.
      # If enabled is false, seconds should be 0 (disables linger).
      def self.set_linger(socket : ::Socket, enabled : Bool, seconds : Int32) : Nil
        socket.linger = enabled ? seconds : 0
      end

      # Gets the SO_BROADCAST option.
      def self.get_broadcast(socket : ::Socket) : Bool
        socket.broadcast?
      end

      # Sets the SO_BROADCAST option.
      def self.set_broadcast(socket : ::Socket, value : Bool) : Nil
        socket.broadcast = value
      end

      # Gets the SO_OOBINLINE option.
      # Not implemented in Crystal's standard library; returns false.
      def self.get_oob_inline(socket : ::Socket) : Bool
        false
      end

      # Sets the SO_OOBINLINE option.
      # Not implemented in Crystal's standard library; no-op.
      def self.set_oob_inline(socket : ::Socket, value : Bool) : Nil
        # no-op
      end

      # Gets the SO_SNDBUF option.
      def self.get_snd_buf(socket : ::Socket) : Int32
        socket.send_buffer_size
      end

      # Sets the SO_SNDBUF option.
      def self.set_snd_buf(socket : ::Socket, value : Int32) : Nil
        socket.send_buffer_size = value
      end

      # Gets the SO_RCVBUF option.
      def self.get_rcv_buf(socket : ::Socket) : Int32
        socket.recv_buffer_size
      end

      # Sets the SO_RCVBUF option.
      def self.set_rcv_buf(socket : ::Socket, value : Int32) : Nil
        socket.recv_buffer_size = value
      end

      # Gets the socket type (STREAM, DGRAM, etc.).
      def self.get_type(socket : ::Socket) : ::Socket::Type
        socket.type
      end

      # Gets the socket error status.
      # Not implemented in Crystal's standard library; returns 0 (no error).
      def self.get_error(socket : ::Socket) : Int32
        0
      end

      # Gets the peer address.
      def self.get_peer_name(socket : ::IPSocket) : ::Socket::Address
        socket.remote_address
      end

      def self.get_peer_name(socket : ::UNIXSocket) : ::Socket::Address
        socket.remote_address
      end

      def self.get_peer_name(socket : ::TCPServer) : ::Socket::Address
        socket.remote_address
      end

      def self.get_peer_name(socket : ::UNIXServer) : ::Socket::Address
        socket.remote_address
      end

      # Gets the socket local address.
      def self.get_sock_name(socket : ::IPSocket) : ::Socket::Address
        socket.local_address
      end

      def self.get_sock_name(socket : ::UNIXSocket) : ::Socket::Address
        socket.local_address
      end

      def self.get_sock_name(socket : ::TCPServer) : ::Socket::Address
        socket.local_address
      end

      def self.get_sock_name(socket : ::UNIXServer) : ::Socket::Address
        socket.local_address
      end

      # Gets the number of bytes available to read.
      # Not available in Crystal's standard library; returns nil.
      def self.get_nread(socket : ::Socket) : Int32?
        nil
      end

      # Checks if the socket is at the out-of-band mark.
      # Not available in Crystal's standard library; returns false.
      def self.get_at_mark(socket : ::Socket) : Bool
        false
      end

      # Wrapper overloads for SocketWrapper types
      def self.get_reuse_addr(socket : SocketWrapper) : Bool
        get_reuse_addr(socket.inner)
      end

      def self.set_reuse_addr(socket : SocketWrapper, value : Bool) : Nil
        set_reuse_addr(socket.inner, value)
      end

      def self.get_keepalive(socket : SocketWrapper) : Bool
        get_keepalive(socket.inner)
      end

      def self.set_keepalive(socket : SocketWrapper, value : Bool) : Nil
        set_keepalive(socket.inner, value)
      end

      def self.get_dont_route(socket : SocketWrapper) : Bool
        get_dont_route(socket.inner)
      end

      def self.set_dont_route(socket : SocketWrapper, value : Bool) : Nil
        set_dont_route(socket.inner, value)
      end

      def self.get_linger(socket : SocketWrapper) : {Bool, Int32}?
        get_linger(socket.inner)
      end

      def self.set_linger(socket : SocketWrapper, enabled : Bool, seconds : Int32) : Nil
        set_linger(socket.inner, enabled, seconds)
      end

      def self.get_broadcast(socket : SocketWrapper) : Bool
        get_broadcast(socket.inner)
      end

      def self.set_broadcast(socket : SocketWrapper, value : Bool) : Nil
        set_broadcast(socket.inner, value)
      end

      def self.get_oob_inline(socket : SocketWrapper) : Bool
        get_oob_inline(socket.inner)
      end

      def self.set_oob_inline(socket : SocketWrapper, value : Bool) : Nil
        set_oob_inline(socket.inner, value)
      end

      def self.get_snd_buf(socket : SocketWrapper) : Int32
        get_snd_buf(socket.inner)
      end

      def self.set_snd_buf(socket : SocketWrapper, value : Int32) : Nil
        set_snd_buf(socket.inner, value)
      end

      def self.get_rcv_buf(socket : SocketWrapper) : Int32
        get_rcv_buf(socket.inner)
      end

      def self.set_rcv_buf(socket : SocketWrapper, value : Int32) : Nil
        set_rcv_buf(socket.inner, value)
      end

      def self.get_type(socket : SocketWrapper) : ::Socket::Type
        get_type(socket.inner)
      end

      def self.get_error(socket : SocketWrapper) : Int32
        get_error(socket.inner)
      end

      def self.get_peer_name(socket : SocketWrapper) : ::Socket::Address
        inner = socket.inner
        if inner.is_a?(::IPSocket) || inner.is_a?(::UNIXSocket) || inner.is_a?(::TCPServer) || inner.is_a?(::UNIXServer)
          inner.remote_address
        else
          raise "Socket type #{inner.class} does not support remote_address"
        end
      end

      def self.get_sock_name(socket : SocketWrapper) : ::Socket::Address
        inner = socket.inner
        if inner.is_a?(::IPSocket) || inner.is_a?(::UNIXSocket) || inner.is_a?(::TCPServer) || inner.is_a?(::UNIXServer)
          inner.local_address
        else
          raise "Socket type #{inner.class} does not support local_address"
        end
      end

      def self.get_nread(socket : SocketWrapper) : Int32?
        get_nread(socket.inner)
      end

      def self.get_at_mark(socket : SocketWrapper) : Bool
        get_at_mark(socket.inner)
      end
    end
  end
end
