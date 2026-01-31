require "socket"
require "../ext/io_wait_readable"
require "./prim_io"
require "../cml"

module CML
  module Socket
    # Socket message flags matching SML/NJ CML_SOCKET signature.
    # Values are platform-specific; these are common Linux/macOS values.
    module Flags
      NONE = 0
      {% if flag?(:linux) || flag?(:darwin) %}
        # Linux and macOS common values
        MSG_OOB       =   0x01 # Process out-of-band data
        MSG_PEEK      =   0x02 # Peek at incoming message
        MSG_DONTROUTE =   0x04 # Don't use local routing
        MSG_CTRUNC    =   0x08 # Control data lost before delivery
        MSG_PROXY     =   0x10 # Supply or ask second address
        MSG_TRUNC     =   0x20 # Data discarded before delivery
        MSG_DONTWAIT  =   0x40 # Non-blocking IO
        MSG_EOR       =   0x80 # End of record
        MSG_WAITALL   =  0x100 # Wait for full request or error
        MSG_FIN       =  0x200 # TCP FIN
        MSG_SYN       =  0x400 # TCP SYN
        MSG_CONFIRM   =  0x800 # Confirm path validity
        MSG_RST       = 0x1000 # TCP RST
        MSG_ERRQUEUE  = 0x2000 # Fetch message from error queue
        MSG_NOSIGNAL  = 0x4000 # Do not generate SIGPIPE
        MSG_MORE      = 0x8000 # Sender will send more
      {% elsif flag?(:windows) %}
        # Windows values (from winsock2.h)
        MSG_OOB       =  0x01 # Process out-of-band data
        MSG_PEEK      =  0x02 # Peek at incoming message
        MSG_DONTROUTE =  0x04 # Don't use local routing
        MSG_WAITALL   =  0x08 # Wait for full request or error
        MSG_PARTIAL   =  0x10 # Partial send or receive
        MSG_INTERRUPT =  0x20 # Interrupt system call (WinSock 1)
        MSG_MAXIOVLEN =  0x40 # Maximum I/O vector length
        MSG_CTRUNC    =  0x80 # Control data truncated
        MSG_BCAST     = 0x100 # Broadcast (not standard)
        MSG_MCAST     = 0x200 # Multicast (not standard)
      {% else %}
        # Fallback values (POSIX defaults)
        MSG_OOB       =   0x01
        MSG_PEEK      =   0x02
        MSG_DONTROUTE =   0x04
        MSG_WAITALL   =  0x100
        MSG_DONTWAIT  =   0x40
        MSG_NOSIGNAL  = 0x4000
      {% end %}
    end

    # TCP accept
    class AcceptEvent < Event(::TCPSocket)
      @server : ::TCPServer
      @nack_evt : Event(Nil)?
      @ready = AtomicFlag.new
      @cancel_flag = AtomicFlag.new
      @result = Slot(Exception | ::TCPSocket).new
      @started = false
      @start_mtx = CML::Sync::Mutex.new

      def initialize(@server, @nack_evt = nil)
      end

      def poll : EventStatus(::TCPSocket)
        if @ready.get
          return Enabled(::TCPSocket).new(priority: 0, value: fetch_result)
        end

        Blocked(::TCPSocket).new do |tid, next_fn|
          start_once(tid)
          next_fn.call
        end
      end

      protected def force_impl : EventGroup(::TCPSocket)
        BaseGroup(::TCPSocket).new(-> : EventStatus(::TCPSocket) { poll })
      end

      private def start_once(tid : TransactionId)
        should_start = false

        @start_mtx.synchronize do
          unless @started
            @started = true
            should_start = true
          end
        end

        return unless should_start

        ::spawn do
          begin
            while wait_until_readable(@server)
              break if @cancel_flag.get
              socket = @server.accept
              deliver(socket, tid)
              break
            end
          rescue ex : Exception
            deliver(ex, tid)
          end
        end

        start_nack_watcher(tid)
      end

      private def start_nack_watcher(tid : TransactionId)
        if nack = @nack_evt
          ::spawn do
            CML.sync(nack)
            @cancel_flag.set(true)
            tid.try_cancel
          end
        end
      end

      private def wait_until_readable(io : ::IO) : Bool
        return false if @cancel_flag.get
        begin
          CML.sync(CML::PrimitiveIO.wait_readable_evt(io, @nack_evt))
          true
        rescue ex : Exception
          # IO closed or nack triggered
          false
        end
      end

      private def deliver(value : Exception | ::TCPSocket, tid : TransactionId)
        return if @cancel_flag.get
        @result.set(value)
        @ready.set(true)
        tid.try_commit_and_resume
      end

      private def fetch_result : ::TCPSocket
        case val = @result.get
        when Exception
          raise val
        else
          val
        end
      end
    end

    # TCP connect
    class ConnectEvent < Event(::TCPSocket)
      @host : String
      @port : Int32
      @nack_evt : Event(Nil)?
      @ready = AtomicFlag.new
      @cancel_flag = AtomicFlag.new
      @result = Slot(Exception | ::TCPSocket).new
      @started = false
      @start_mtx = CML::Sync::Mutex.new

      def initialize(@host, @port, @nack_evt = nil)
      end

      def poll : EventStatus(::TCPSocket)
        if @ready.get
          return Enabled(::TCPSocket).new(priority: 0, value: fetch_result)
        end

        Blocked(::TCPSocket).new do |tid, next_fn|
          start_once(tid)
          next_fn.call
        end
      end

      protected def force_impl : EventGroup(::TCPSocket)
        BaseGroup(::TCPSocket).new(-> : EventStatus(::TCPSocket) { poll })
      end

      private def start_once(tid : TransactionId)
        should_start = false

        @start_mtx.synchronize do
          unless @started
            @started = true
            should_start = true
          end
        end

        return unless should_start

        ::spawn do
          begin
            socket = ::TCPSocket.new(@host, @port)
            deliver(socket, tid)
          rescue ex : Exception
            deliver(ex, tid)
          end
        end

        start_nack_watcher(tid)
      end

      private def start_nack_watcher(tid : TransactionId)
        if nack = @nack_evt
          ::spawn do
            CML.sync(nack)
            @cancel_flag.set(true)
            tid.try_cancel
          end
        end
      end

      private def deliver(value : Exception | ::TCPSocket, tid : TransactionId)
        return if @cancel_flag.get
        @result.set(value)
        @ready.set(true)
        tid.try_commit_and_resume
      end

      private def fetch_result : ::TCPSocket
        case val = @result.get
        when Exception
          raise val
        else
          val
        end
    end
  end

  # Unix domain socket accept
  class UnixAcceptEvent < Event(::UNIXSocket)
    @server : ::UNIXServer
    @nack_evt : Event(Nil)?
    @ready = AtomicFlag.new
    @cancel_flag = AtomicFlag.new
    @result = Slot(Exception | ::UNIXSocket).new
    @started = false
    @start_mtx = CML::Sync::Mutex.new

    def initialize(@server, @nack_evt = nil)
    end

    def poll : EventStatus(::UNIXSocket)
      if @ready.get
        return Enabled(::UNIXSocket).new(priority: 0, value: fetch_result)
      end

      Blocked(::UNIXSocket).new do |tid, next_fn|
        start_once(tid)
        next_fn.call
      end
    end

    protected def force_impl : EventGroup(::UNIXSocket)
      BaseGroup(::UNIXSocket).new(-> : EventStatus(::UNIXSocket) { poll })
    end

    private def start_once(tid : TransactionId)
      should_start = false

      @start_mtx.synchronize do
        unless @started
          @started = true
          should_start = true
        end
      end

      return unless should_start

      ::spawn do
        begin
          while wait_until_readable(@server)
            break if @cancel_flag.get
            socket = @server.accept
            deliver(socket, tid)
            break
          end
        rescue ex : Exception
          deliver(ex, tid)
        end
      end

      start_nack_watcher(tid)
    end

    private def start_nack_watcher(tid : TransactionId)
      if nack = @nack_evt
        ::spawn do
          CML.sync(nack)
          @cancel_flag.set(true)
          tid.try_cancel
        end
      end
    end

      private def wait_until_readable(io : ::IO) : Bool
        return false if @cancel_flag.get
        begin
          CML.sync(CML::PrimitiveIO.wait_readable_evt(io, @nack_evt))
          true
        rescue ex : Exception
          # IO closed or nack triggered
          false
        end
      end

    private def deliver(value : Exception | ::UNIXSocket, tid : TransactionId)
      return if @cancel_flag.get
      @result.set(value)
      @ready.set(true)
      tid.try_commit_and_resume
    end

    private def fetch_result : ::UNIXSocket
      case val = @result.get
      when Exception
        raise val
      else
        val
      end
    end
  end

  # Unix domain socket connect
  class UnixConnectEvent < Event(::UNIXSocket)
    @path : String
    @nack_evt : Event(Nil)?
    @ready = AtomicFlag.new
    @cancel_flag = AtomicFlag.new
    @result = Slot(Exception | ::UNIXSocket).new
    @started = false
    @start_mtx = CML::Sync::Mutex.new

    def initialize(@path, @nack_evt = nil)
    end

    def poll : EventStatus(::UNIXSocket)
      if @ready.get
        return Enabled(::UNIXSocket).new(priority: 0, value: fetch_result)
      end

      Blocked(::UNIXSocket).new do |tid, next_fn|
        start_once(tid)
        next_fn.call
      end
    end

    protected def force_impl : EventGroup(::UNIXSocket)
      BaseGroup(::UNIXSocket).new(-> : EventStatus(::UNIXSocket) { poll })
    end

    private def start_once(tid : TransactionId)
      should_start = false

      @start_mtx.synchronize do
        unless @started
          @started = true
          should_start = true
        end
      end

      return unless should_start

      ::spawn do
        begin
          socket = ::UNIXSocket.new(@path)
          deliver(socket, tid)
        rescue ex : Exception
          deliver(ex, tid)
        end
      end

      start_nack_watcher(tid)
    end

    private def start_nack_watcher(tid : TransactionId)
      if nack = @nack_evt
        ::spawn do
          CML.sync(nack)
          @cancel_flag.set(true)
          tid.try_cancel
        end
      end
    end

    private def deliver(value : Exception | ::UNIXSocket, tid : TransactionId)
      return if @cancel_flag.get
      @result.set(value)
      @ready.set(true)
      tid.try_commit_and_resume
    end

    private def fetch_result : ::UNIXSocket
      case val = @result.get
      when Exception
        raise val
      else
        val
      end
    end
  end

  # Receive bytes from a socket using readiness polling.
    class RecvEvent < Event(Bytes)
      @socket : ::Socket
      @length : Int32
      @flags : Int32
      @nack_evt : Event(Nil)?
      @ready = AtomicFlag.new
      @cancel_flag = AtomicFlag.new
      @result = Slot(Exception | Bytes).new
      @started = false
      @start_mtx = CML::Sync::Mutex.new

      def initialize(@socket, @length, @flags = 0, @nack_evt = nil)
      end

      def poll : EventStatus(Bytes)
        if @ready.get
          return Enabled(Bytes).new(priority: 0, value: fetch_result)
        end

        Blocked(Bytes).new do |tid, next_fn|
          start_once(tid)
          next_fn.call
        end
      end

      protected def force_impl : EventGroup(Bytes)
        BaseGroup(Bytes).new(-> : EventStatus(Bytes) { poll })
      end

      private def start_once(tid : TransactionId)
        should_start = false

        @start_mtx.synchronize do
          unless @started
            @started = true
            should_start = true
          end
        end

        return unless should_start

        ::spawn do
          begin
            CML.trace "RecvEvent.start_once loop", @socket, tag: "socket"
            while wait_until_readable(@socket)
              break if @cancel_flag.get
              buffer = Bytes.new(@length)
              read_bytes = if @flags == 0
                             @socket.read(buffer)
                           else
                             # Use low-level recv with flags
                             loop do
                               bytes = LibC.recv(@socket.fd, buffer, @length, @flags)
                               if bytes < 0
                                 errno = Errno.value
                                 if errno == Errno::EAGAIN || errno == Errno::EWOULDBLOCK
                                    # Not ready yet, wait a bit and retry
                                    CML.trace "RecvEvent.inner wait", @socket, tag: "socket"
                                    CML.sync(CML::PrimitiveIO.wait_readable_evt(@socket, @nack_evt))
                                   next
                                 else
                                   raise IO::Error.from_os_error("recv", errno)
                                 end
                               end
                               break bytes.to_i32
                             end
                           end
              deliver(buffer[0, read_bytes], tid)
              break
            end
          rescue ex : Exception
            deliver(ex, tid)
          end
        end

        start_nack_watcher(tid)
      end

      private def wait_until_readable(io : ::IO) : Bool
        return false if @cancel_flag.get
        begin
          io.wait_readable(50.milliseconds, raise_if_closed: false)
          true
        rescue ex : IO::TimeoutError
          false
        rescue
          true
        end
      end

      private def start_nack_watcher(tid : TransactionId)
        if nack = @nack_evt
          ::spawn do
            CML.sync(nack)
            @cancel_flag.set(true)
            tid.try_cancel
          end
        end
      end

      private def deliver(value : Exception | Bytes, tid : TransactionId)
        return if @cancel_flag.get
        @result.set(value)
        @ready.set(true)
        tid.try_commit_and_resume
      end

      private def fetch_result : Bytes
        case val = @result.get
        when Exception
          raise val
        else
          val
        end
      end
    end

    # Send bytes on a socket using readiness polling.
    class SendEvent < Event(Int32)
      @socket : ::Socket
      @data : Bytes
      @flags : Int32
      @nack_evt : Event(Nil)?
      @ready = AtomicFlag.new
      @cancel_flag = AtomicFlag.new
      @result = Slot(Exception | Int32).new
      @started = false
      @start_mtx = CML::Sync::Mutex.new

      def initialize(@socket, data : Bytes, flags : Int32 = 0, @nack_evt = nil)
        @data = data.dup
        @flags = flags
      end

      def poll : EventStatus(Int32)
        if @ready.get
          return Enabled(Int32).new(priority: 0, value: fetch_result)
        end

        Blocked(Int32).new do |tid, next_fn|
          start_once(tid)
          next_fn.call
        end
      end

      protected def force_impl : EventGroup(Int32)
        BaseGroup(Int32).new(-> : EventStatus(Int32) { poll })
      end

      private def start_once(tid : TransactionId)
        should_start = false

        @start_mtx.synchronize do
          unless @started
            @started = true
            should_start = true
          end
        end

        return unless should_start

        ::spawn do
          begin
            bytes_written = 0
            while wait_until_writable(@socket) && bytes_written < @data.size
              break if @cancel_flag.get
              slice = @data[bytes_written..]
              bytes_sent = if @flags == 0
                             @socket.write(slice)
                             slice.size
                           else
                             # Use low-level send with flags
                             bytes = LibC.send(@socket.fd, slice, slice.size, @flags)
                             if bytes < 0
                               errno = Errno.value
                               raise IO::Error.from_os_error("send", errno)
                             end
                             bytes.to_i32
                           end
              bytes_written += bytes_sent
            end
            deliver(bytes_written, tid)
          rescue ex : Exception
            deliver(ex, tid)
          end
        end

        start_nack_watcher(tid)
      end

      private def wait_until_writable(io : ::IO) : Bool
        return false if @cancel_flag.get
        begin
          io.wait_writable(50.milliseconds)
          true
        rescue ex : IO::TimeoutError
          false
        rescue
          true
        end
      end

      private def start_nack_watcher(tid : TransactionId)
        if nack = @nack_evt
          ::spawn do
            CML.sync(nack)
            @cancel_flag.set(true)
            tid.try_cancel
          end
        end
      end

      private def deliver(value : Exception | Int32, tid : TransactionId)
        return if @cancel_flag.get
        @result.set(value)
        @ready.set(true)
        tid.try_commit_and_resume
      end

      private def fetch_result : Int32
        case val = @result.get
        when Exception
          raise val
        else
          val
        end
      end
    end

    module UDP
      class SendEvent < Event(Int32)
        @socket : ::UDPSocket
        @data : Bytes
        @host : String?
        @port : Int32?
        @flags : Int32
        @nack_evt : Event(Nil)?
        @ready = AtomicFlag.new
        @cancel_flag = AtomicFlag.new
        @result = Slot(Exception | Int32).new
        @started = false
        @start_mtx = CML::Sync::Mutex.new

        def initialize(@socket, data : Bytes, @host = nil, @port = nil, flags : Int32 = 0, @nack_evt = nil)
          @data = data.dup
          @flags = flags
        end

        def poll : EventStatus(Int32)
          if @ready.get
            return Enabled(Int32).new(priority: 0, value: fetch_result)
          end

          Blocked(Int32).new do |tid, next_fn|
            start_once(tid)
            next_fn.call
          end
        end

        protected def force_impl : EventGroup(Int32)
          BaseGroup(Int32).new(-> : EventStatus(Int32) { poll })
        end

        private def start_once(tid : TransactionId)
          should_start = false

          @start_mtx.synchronize do
            unless @started
              @started = true
              should_start = true
            end
          end

          return unless should_start

          ::spawn do
            begin
              bytes_sent = if @flags == 0
                             if @host && @port
                               addr = ::Socket::IPAddress.new(@host.not_nil!, @port.not_nil!)
                               @socket.send(@data, addr)
                             else
                               @socket.send(@data)
                             end
                           else
                             # Use low-level sendto with flags
                             if @host && @port
                               addr = ::Socket::IPAddress.new(@host.not_nil!, @port.not_nil!)
                               sockaddr = addr.to_unsafe
                               bytes = LibC.sendto(@socket.fd, @data, @data.size, @flags, sockaddr, addr.size.to_u32)
                             else
                               # connected socket
                               bytes = LibC.send(@socket.fd, @data, @data.size, @flags)
                             end
                             if bytes < 0
                               errno = Errno.value
                               raise IO::Error.from_os_error("send", errno)
                             end
                             bytes.to_i32
                           end
              deliver(bytes_sent, tid)
            rescue ex : Exception
              deliver(ex, tid)
            end
          end

          start_nack_watcher(tid)
        end

        private def start_nack_watcher(tid : TransactionId)
          if nack = @nack_evt
            ::spawn do
              CML.sync(nack)
              @cancel_flag.set(true)
              tid.try_cancel
            end
          end
        end

        private def deliver(value : Exception | Int32, tid : TransactionId)
          return if @cancel_flag.get
          @result.set(value)
          @ready.set(true)
          tid.try_commit_and_resume
        end

        private def fetch_result : Int32
          case val = @result.get
          when Exception
            raise val
          else
            val
          end
        end
      end

      class RecvEvent < Event({Bytes, ::Socket::IPAddress})
        @socket : ::UDPSocket
        @max : Int32
        @flags : Int32
        @nack_evt : Event(Nil)?
        @ready = AtomicFlag.new
        @cancel_flag = AtomicFlag.new
        @result = Slot(Exception | {Bytes, ::Socket::IPAddress}).new
        @started = false
        @start_mtx = CML::Sync::Mutex.new

        def initialize(@socket, @max, flags : Int32 = 0, @nack_evt = nil)
          @flags = flags
        end

        def poll : EventStatus({Bytes, ::Socket::IPAddress})
          if @ready.get
            return Enabled({Bytes, ::Socket::IPAddress}).new(priority: 0, value: fetch_result)
          end

          Blocked({Bytes, ::Socket::IPAddress}).new do |tid, next_fn|
            start_once(tid)
            next_fn.call
          end
        end

        protected def force_impl : EventGroup({Bytes, ::Socket::IPAddress})
          BaseGroup({Bytes, ::Socket::IPAddress}).new(-> : EventStatus({Bytes, ::Socket::IPAddress}) { poll })
        end

        private def start_once(tid : TransactionId)
          should_start = false

          @start_mtx.synchronize do
            unless @started
              @started = true
              should_start = true
            end
          end

          return unless should_start

          ::spawn do
            begin
              while wait_until_readable(@socket)
                break if @cancel_flag.get
                data_raw, addr = @socket.receive
                data_bytes = data_raw.is_a?(Bytes) ? data_raw.as(Bytes) : data_raw.to_slice
                deliver({data_bytes, addr}, tid)
                break
              end
            rescue ex : Exception
              deliver(ex, tid)
            end
          end

          start_nack_watcher(tid)
        end

      private def wait_until_readable(io : ::IO) : Bool
        return false if @cancel_flag.get
        begin
          CML.sync(CML::PrimitiveIO.wait_readable_evt(io, @nack_evt))
          true
        rescue ex : Exception
          # If wait_readable_evt raises (e.g., IO closed), return true to let the loop handle it
          true
        end
      end

        private def start_nack_watcher(tid : TransactionId)
          if nack = @nack_evt
            ::spawn do
              CML.sync(nack)
              @cancel_flag.set(true)
              tid.try_cancel
            end
          end
        end

        private def deliver(value : Exception | {Bytes, ::Socket::IPAddress}, tid : TransactionId)
          return if @cancel_flag.get
          @result.set(value)
          @ready.set(true)
          tid.try_commit_and_resume
        end

        private def fetch_result : {Bytes, ::Socket::IPAddress}
          case val = @result.get
          when Exception
            raise val
          else
            val
          end
        end
      end

      def self.send_evt(socket : ::UDPSocket, data : Bytes, host : String? = nil, port : Int32? = nil, flags : Int32 = 0) : Event(Int32)
        CML.with_nack do |nack|
          SendEvent.new(socket, data, host, port, flags, nack)
        end
      end

      def self.recv_evt(socket : ::UDPSocket, max : Int32, flags : Int32 = 0) : Event({Bytes, ::Socket::IPAddress})
        CML.with_nack do |nack|
          RecvEvent.new(socket, max, flags, nack)
        end
      end

      def self.send_evt(socket : Socket::DatagramSocket, data : Bytes, host : String? = nil, port : Int32? = nil, flags : Int32 = 0) : Event(Int32)
        send_evt(socket.inner, data, host, port, flags)
      end

      def self.recv_evt(socket : Socket::DatagramSocket, max : Int32, flags : Int32 = 0) : Event({Bytes, ::Socket::IPAddress})
        recv_evt(socket.inner, max, flags)
      end
    end

    def self.accept_evt(server : ::TCPServer) : Event(::TCPSocket)
      CML.with_nack { |nack| AcceptEvent.new(server, nack) }
    end

    def self.accept_evt(server : Socket::PassiveSocket) : Event(::TCPSocket)
      accept_evt(server.inner)
    end

    def self.connect_evt(host : String, port : Int32) : Event(::TCPSocket)
      CML.with_nack { |nack| ConnectEvent.new(host, port, nack) }
    end

    def self.accept_evt(server : ::UNIXServer) : Event(::UNIXSocket)
      CML.with_nack { |nack| UnixAcceptEvent.new(server, nack) }
    end

    def self.accept_evt(server : Socket::UnixPassiveSocket) : Event(::UNIXSocket)
      accept_evt(server.inner)
    end

    def self.unix_connect_evt(path : String) : Event(::UNIXSocket)
      CML.with_nack { |nack| UnixConnectEvent.new(path, nack) }
    end

    def self.recv_evt(socket : ::Socket, length : Int32, flags : Int32 = 0) : Event(Bytes)
      CML.with_nack { |nack| RecvEvent.new(socket, length, flags, nack) }
    end

    def self.send_evt(socket : ::Socket, data : Bytes, flags : Int32 = 0) : Event(Int32)
      CML.with_nack { |nack| SendEvent.new(socket, data, flags, nack) }
    end

    def self.recv_evt(socket : Socket::StreamSocket, length : Int32, flags : Int32 = 0) : Event(Bytes)
      recv_evt(socket.inner, length, flags)
    end

    def self.send_evt(socket : Socket::StreamSocket, data : Bytes, flags : Int32 = 0) : Event(Int32)
      send_evt(socket.inner, data, flags)
    end

    def self.recv_evt(socket : Socket::UnixStreamSocket, length : Int32, flags : Int32 = 0) : Event(Bytes)
      recv_evt(socket.inner, length, flags)
    end

    def self.send_evt(socket : Socket::UnixStreamSocket, data : Bytes, flags : Int32 = 0) : Event(Int32)
      send_evt(socket.inner, data, flags)
    end

    def self.recv_evt(socket : Socket::UnixDatagramSocket, length : Int32, flags : Int32 = 0) : Event(Bytes)
      recv_evt(socket.inner, length, flags)
    end

    def self.send_evt(socket : Socket::UnixDatagramSocket, data : Bytes, flags : Int32 = 0) : Event(Int32)
      send_evt(socket.inner, data, flags)
    end
  end
end
