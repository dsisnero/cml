require "socket"
require "../cml"

module CML
  module Socket
    # Base wrapper class for all CML socket wrappers.
    # Provides access to the underlying raw socket and common operations.
    abstract class SocketWrapper
      # Returns the underlying raw socket.
      abstract def inner : ::Socket

      # Closes the socket.
      def close
        inner.close
      end

      # Returns whether the socket is closed.
      def closed?
        inner.closed?
      end

      # Returns the local address.
      def local_address
        inner.local_address
      end

      # Returns the remote address.
      def remote_address
        inner.remote_address
      end
    end

    # Wrapper for active stream sockets (TCP connected sockets).
    class StreamSocket < SocketWrapper
      @inner : ::TCPSocket

      def initialize(@inner : ::TCPSocket)
      end

      def inner : ::TCPSocket
        @inner
      end

      # Connect to a remote host.
      def connect(host, port)
        @inner.connect(host, port)
      end

      # Bind to a local address.
      def bind(host, port)
        @inner.bind(host, port)
      end

      # Listen for incoming connections.
      def listen(backlog = ::Socket::DEFAULT_BACKLOG)
        @inner.listen(backlog)
      end
    end

    # Wrapper for datagram sockets (UDP sockets).
    class DatagramSocket < SocketWrapper
      @inner : ::UDPSocket

      def initialize(@inner : ::UDPSocket)
      end

      def inner : ::UDPSocket
        @inner
      end

      # Bind to a local address.
      def bind(host, port)
        @inner.bind(host, port)
      end
    end

    # Wrapper for passive stream sockets (listening servers).
    class PassiveSocket < SocketWrapper
      @inner : ::TCPServer

      def initialize(@inner : ::TCPServer)
      end

      def inner : ::TCPServer
        @inner
      end

      # Bind to a local address.
      def bind(host, port)
        @inner.bind(host, port)
      end

      # Listen for incoming connections.
      def listen(backlog = ::Socket::DEFAULT_BACKLOG)
        @inner.listen(backlog)
      end
    end

    # Wrapper for Unix stream sockets.
    class UnixStreamSocket < SocketWrapper
      @inner : ::UNIXSocket

      def initialize(@inner : ::UNIXSocket)
      end

      def inner : ::UNIXSocket
        @inner
      end
    end

    # Wrapper for Unix datagram sockets.
    class UnixDatagramSocket < SocketWrapper
      @inner : ::UNIXSocket

      def initialize(@inner : ::UNIXSocket)
      end

      def inner : ::UNIXSocket
        @inner
      end
    end

    # Wrapper for Unix passive sockets (Unix servers).
    class UnixPassiveSocket < SocketWrapper
      @inner : ::UNIXServer

      def initialize(@inner : ::UNIXServer)
      end

      def inner : ::UNIXServer
        @inner
      end
    end

    # Factory functions matching SML/NJ GENERIC_SOCK signature
    module Factory
      private def to_family(family) : ::Socket::Family
        case family
        when ::Socket::Family
          family
        when Symbol
          case family
          when :inet  then ::Socket::Family::INET
          when :inet6 then ::Socket::Family::INET6
          when :unix  then ::Socket::Family::UNIX
          else             raise ArgumentError.new("Unsupported address family: #{family}")
          end
        else
          raise ArgumentError.new("Address family must be Symbol or Socket::Family")
        end
      end

      private def to_type(type) : ::Socket::Type
        case type
        when ::Socket::Type
          type
        when Symbol
          case type
          when :stream then ::Socket::Type::STREAM
          when :dgram  then ::Socket::Type::DGRAM
          when :raw    then ::Socket::Type::RAW
          else              raise ArgumentError.new("Unsupported socket type: #{type}")
          end
        else
          raise ArgumentError.new("Socket type must be Symbol or Socket::Type")
        end
      end

      private def create_raw_socket(family : ::Socket::Family, type : ::Socket::Type, protocol : ::Socket::Protocol = ::Socket::Protocol::IP) : ::Socket
        case {family, type}
        when {::Socket::Family::INET, ::Socket::Type::STREAM}
          ::TCPSocket.new
        when {::Socket::Family::INET, ::Socket::Type::DGRAM}
          ::UDPSocket.new
        when {::Socket::Family::INET6, ::Socket::Type::STREAM}
          ::TCPSocket.new
        when {::Socket::Family::INET6, ::Socket::Type::DGRAM}
          ::UDPSocket.new
        when {::Socket::Family::UNIX, ::Socket::Type::STREAM}
          ::Socket.new(family, type, protocol)
        when {::Socket::Family::UNIX, ::Socket::Type::DGRAM}
          ::Socket.new(family, type, protocol)
        else
          # Fallback to generic socket
          ::Socket.new(family, type, protocol)
        end
      end

      private def wrap_socket(raw : ::Socket, family : ::Socket::Family, type : ::Socket::Type) : SocketWrapper
        case {family, type}
        when {::Socket::Family::INET, ::Socket::Type::STREAM}
          if raw.is_a?(::TCPServer)
            PassiveSocket.new(raw.as(::TCPServer))
          elsif raw.is_a?(::TCPSocket)
            StreamSocket.new(raw.as(::TCPSocket))
          else
            # Generic socket, fallback to generic wrapper
            GenericSocketWrapper.new(raw)
          end
        when {::Socket::Family::INET, ::Socket::Type::DGRAM}
          if raw.is_a?(::UDPSocket)
            DatagramSocket.new(raw.as(::UDPSocket))
          else
            GenericSocketWrapper.new(raw)
          end
        when {::Socket::Family::INET6, ::Socket::Type::STREAM}
          if raw.is_a?(::TCPServer)
            PassiveSocket.new(raw.as(::TCPServer))
          elsif raw.is_a?(::TCPSocket)
            StreamSocket.new(raw.as(::TCPSocket))
          else
            GenericSocketWrapper.new(raw)
          end
        when {::Socket::Family::INET6, ::Socket::Type::DGRAM}
          if raw.is_a?(::UDPSocket)
            DatagramSocket.new(raw.as(::UDPSocket))
          else
            GenericSocketWrapper.new(raw)
          end
        when {::Socket::Family::UNIX, ::Socket::Type::STREAM}
          if raw.is_a?(::UNIXServer)
            UnixPassiveSocket.new(raw.as(::UNIXServer))
          elsif raw.is_a?(::UNIXSocket)
            UnixStreamSocket.new(raw.as(::UNIXSocket))
          else
            # Generic socket, fallback to generic wrapper
            GenericSocketWrapper.new(raw)
          end
        when {::Socket::Family::UNIX, ::Socket::Type::DGRAM}
          if raw.is_a?(::UNIXSocket)
            UnixDatagramSocket.new(raw.as(::UNIXSocket))
          else
            GenericSocketWrapper.new(raw)
          end
        else
          # Fallback to generic wrapper
          GenericSocketWrapper.new(raw)
        end
      end

      private def create_socket_pair(family : ::Socket::Family, type : ::Socket::Type, protocol : ::Socket::Protocol = ::Socket::Protocol::IP) : {::Socket, ::Socket}
        if family == ::Socket::Family::UNIX
          return ::UNIXSocket.pair(type)
        end

        # INET/INET6: create a loopback connection
        case type
        when ::Socket::Type::STREAM
          create_inet_stream_pair(family, protocol)
        when ::Socket::Type::DGRAM
          create_inet_datagram_pair(family, protocol)
        else
          raise ArgumentError.new("Socket type #{type} not supported for INET socket pair")
        end
      end

      private def create_inet_stream_pair(family : ::Socket::Family, protocol : ::Socket::Protocol) : {::Socket, ::Socket}
        # Determine loopback address based on family
        loopback = case family
                   when ::Socket::Family::INET
                     "127.0.0.1"
                   when ::Socket::Family::INET6
                     "::1"
                   else
                     raise ArgumentError.new("Unsupported address family for stream pair: #{family}")
                   end

        # Create a TCP server socket
        server = ::TCPServer.new(loopback, 0)
        port = server.local_address.port

        # Create client TCP socket
        client = ::TCPSocket.new
        client.connect(loopback, port)

        # Accept connection
        accepted = server.accept
        server.close

        {client, accepted}
      end

      private def create_inet_datagram_pair(family : ::Socket::Family, protocol : ::Socket::Protocol) : {::Socket, ::Socket}
        # Determine loopback address based on family
        loopback = case family
                   when ::Socket::Family::INET
                     "127.0.0.1"
                   when ::Socket::Family::INET6
                     "::1"
                   else
                     raise ArgumentError.new("Unsupported address family for datagram pair: #{family}")
                   end

        # Create two UDP sockets
        sock1 = ::UDPSocket.new
        sock2 = ::UDPSocket.new

        sock1.bind(loopback, 0)
        sock2.bind(loopback, 0)

        addr1 = sock1.local_address
        addr2 = sock2.local_address

        sock1.connect(addr2)
        sock2.connect(addr1)

        {sock1, sock2}
      end

      # Create a socket using default protocol.
      # address_family: :inet, :inet6, :unix, etc. (Symbol or Socket::Family)
      # sock_type: :stream, :dgram, :raw, etc. (Symbol or Socket::Type)
      def socket(address_family, sock_type) : SocketWrapper
        af = to_family(address_family)
        st = to_type(sock_type)
        raw = create_raw_socket(af, st)
        wrap_socket(raw, af, st)
      end

      # Create a pair of connected sockets using default protocol.
      def socket_pair(address_family, sock_type) : {SocketWrapper, SocketWrapper}
        af = to_family(address_family)
        st = to_type(sock_type)
        left, right = create_socket_pair(af, st)
        wrapper = wrap_socket(left, af, st)
        wrapper2 = wrap_socket(right, af, st)
        {wrapper, wrapper2}
      end

      # Create a socket using specified protocol.
      def socket_with_protocol(address_family, sock_type, protocol) : SocketWrapper
        af = to_family(address_family)
        st = to_type(sock_type)
        raw = create_raw_socket(af, st, ::Socket::Protocol.new(protocol))
        wrap_socket(raw, af, st)
      end

      # Create a pair of connected sockets using specified protocol.
      def socket_pair_with_protocol(address_family, sock_type, protocol) : {SocketWrapper, SocketWrapper}
        af = to_family(address_family)
        st = to_type(sock_type)
        left, right = create_socket_pair(af, st, ::Socket::Protocol.new(protocol))
        wrapper = wrap_socket(left, af, st)
        wrapper2 = wrap_socket(right, af, st)
        {wrapper, wrapper2}
      end

      # Convenience factory for TCP stream socket (active, not connected).
      def tcp : StreamSocket
        raw = ::TCPSocket.new
        StreamSocket.new(raw)
      end

      # Convenience factory for UDP datagram socket.
      def udp : DatagramSocket
        raw = ::UDPSocket.new
        DatagramSocket.new(raw)
      end

      # Convenience factory for TCP passive socket (server).
      def tcp_server(host : String? = nil, port : Int32? = nil) : PassiveSocket
        raw = ::TCPServer.new(host, port)
        PassiveSocket.new(raw)
      end

      # Convenience factory for Unix stream socket.
      def unix_stream : UnixStreamSocket
        raw = ::UNIXSocket.new
        UnixStreamSocket.new(raw)
      end

      # Convenience factory for Unix datagram socket.
      def unix_dgram : UnixDatagramSocket
        raw = ::UNIXSocket.new(::Socket::Type::DGRAM)
        UnixDatagramSocket.new(raw)
      end

      # Convenience factory for Unix passive socket (server).
      def unix_server(path : String? = nil) : UnixPassiveSocket
        raw = ::UNIXServer.new(path)
        UnixPassiveSocket.new(raw)
      end
    end

    # Generic wrapper for sockets that don't fit specific categories.
    class GenericSocketWrapper < SocketWrapper
      @inner : ::Socket

      def initialize(@inner : ::Socket)
      end

      def inner : ::Socket
        @inner
      end
    end

    # Extend the main Socket module with factory methods.
    extend Factory
  end
end
