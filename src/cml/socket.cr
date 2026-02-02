require "socket"
require "../ext/io_wait_readable"
require "./prim_io"
require "../cml"

class ::TCPSocket
  def self.from_handle(handle : ::Socket::Handle, family : ::Socket::Family, type : ::Socket::Type, protocol : ::Socket::Protocol, blocking : Bool? = nil) : ::TCPSocket
    sock = allocate
    sock.initialize(handle: handle, family: family, type: type, protocol: protocol, blocking: blocking)
    sock
  end
end

class ::UNIXSocket
  def self.from_handle(handle : ::Socket::Handle, type : ::Socket::Type = ::Socket::Type::STREAM, path : Path | String? = nil, blocking : Bool? = nil) : ::UNIXSocket
    sock = allocate
    sock.initialize(handle: handle, type: type, path: path, blocking: blocking)
    sock
  end
end

module CML
  module Socket
    # Socket message flags matching SML/NJ CML_SOCKET signature.
    # Values are platform-specific; these are common Linux/macOS values.
    module Flags
      NONE = 0
      {% if flag?(:linux) %}
        # Linux values
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
      {% elsif flag?(:darwin) %}
        # macOS values (from sys/socket.h)
        MSG_OOB       =    0x01 # Process out-of-band data
        MSG_PEEK      =    0x02 # Peek at incoming message
        MSG_DONTROUTE =    0x04 # Don't use local routing
        MSG_EOR       =    0x08 # End of record
        MSG_TRUNC     =   0x10 # Data discarded before delivery
        MSG_CTRUNC    =   0x20 # Control data lost before delivery
        MSG_WAITALL   =   0x40 # Wait for full request or error
        MSG_DONTWAIT  =   0x80 # Non-blocking IO
        MSG_EOF       =  0x100 # Data completes connection
        MSG_WAITSTREAM = 0x200 # Wait up to full request.. may return partial
        MSG_FLUSH     =  0x400 # Start of 'hold' seq; dump so_temp (deprecated)
        MSG_HOLD      =  0x800 # Hold frag in so_temp (deprecated)
        MSG_SEND      = 0x1000 # Send the packet in so_temp (deprecated)
        MSG_HAVEMORE  = 0x2000 # Data ready to be read
        MSG_RCVMORE   = 0x4000 # Data remains in current pkt
        MSG_NEEDSA    = 0x10000 # Fail receive if socket address cannot be allocated
        MSG_NOSIGNAL  = 0x80000 # Do not generate SIGPIPE on EOF
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

    # Input flags (SML/NJ in_flags).
    struct InFlags
      getter peek : Bool
      getter oob : Bool

      def initialize(@peek : Bool = false, @oob : Bool = false)
      end
    end

    # Output flags (SML/NJ out_flags).
    struct OutFlags
      getter dont_route : Bool
      getter oob : Bool

      def initialize(@dont_route : Bool = false, @oob : Bool = false)
      end
    end

    def self.in_flags_to_int(flags : InFlags) : Int32
      value = Flags::NONE
      value |= Flags::MSG_PEEK if flags.peek
      value |= Flags::MSG_OOB if flags.oob
      value
    end

    def self.out_flags_to_int(flags : OutFlags) : Int32
      value = Flags::NONE
      value |= Flags::MSG_DONTROUTE if flags.dont_route
      value |= Flags::MSG_OOB if flags.oob
      value
    end

    def self.nonblock_flags(extra : Int32 = Flags::NONE) : Int32
      value = extra
      {% if Flags.has_constant?(:MSG_DONTWAIT) %}
        value |= Flags::MSG_DONTWAIT
      {% end %}
      value
    end

    def self.try_accept_fd(server : ::Socket) : {::Socket::Handle, ::Socket::Address}?
      addr = uninitialized LibC::SockaddrStorage
      addr_len = LibC::SocklenT.new(sizeof(LibC::SockaddrStorage))
      fd = LibC.accept(server.fd, pointerof(addr).as(LibC::Sockaddr*), pointerof(addr_len))
      if fd < 0
        err = Errno.value
        return nil if err == Errno::EAGAIN || err == Errno::EWOULDBLOCK || err == Errno::EINTR
        raise IO::Error.from_os_error("accept", err)
      end
      address = ::Socket::Address.from(pointerof(addr).as(LibC::Sockaddr*), addr_len)
      {fd, address}
    end

    def self.connect_nonblock(socket : ::Socket, address : ::Socket::Address) : Bool?
      rc = LibC.connect(socket.fd, address, address.size)
      return true if rc == 0
      err = Errno.value
      case err
      when Errno::EISCONN
        true
      when Errno::EINPROGRESS, Errno::EALREADY, Errno::EWOULDBLOCK
        nil
      else
        raise IO::Error.from_os_error("connect", err)
      end
    end

    # TCP accept
    class AcceptEvent < Event({::TCPSocket, ::Socket::Address})
      @server : ::TCPServer
      @nack_evt : Event(Nil)?
      @ready = AtomicFlag.new
      @cancel_flag = AtomicFlag.new
      @result = Slot(Exception | {::TCPSocket, ::Socket::Address}).new
      @started = false
      @start_mtx = CML::Sync::Mutex.new

      def initialize(@server, @nack_evt = nil)
      end

      def poll : EventStatus({::TCPSocket, ::Socket::Address})
        if @ready.get
          CML.trace "AcceptEvent.poll ready", tag: "socket"
          return Enabled({::TCPSocket, ::Socket::Address}).new(priority: 0, value: fetch_result)
        end

        if result = try_accept_nonblock
          CML.trace "AcceptEvent.poll immediate", tag: "socket"
          store_result(result)
          return Enabled({::TCPSocket, ::Socket::Address}).new(priority: 0, value: result)
        end

        Blocked({::TCPSocket, ::Socket::Address}).new do |tid, next_fn|
          start_once(tid)
          next_fn.call
        end
      end

      protected def force_impl : EventGroup({::TCPSocket, ::Socket::Address})
        BaseGroup({::TCPSocket, ::Socket::Address}).new(-> : EventStatus({::TCPSocket, ::Socket::Address}) { poll })
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
            CML.trace "AcceptEvent.start_once begin", tag: "socket"
            while wait_until_readable(@server)
              break if @cancel_flag.get
              if result = try_accept_nonblock
                CML.trace "AcceptEvent.start_once accepted", tag: "socket"
                deliver(result, tid)
                break
              end
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

      private def deliver(value : Exception | {::TCPSocket, ::Socket::Address}, tid : TransactionId)
        return if @cancel_flag.get
        @result.set(value)
        @ready.set(true)
        tid.try_commit_and_resume
      end

      private def fetch_result : {::TCPSocket, ::Socket::Address}
        case val = @result.get
        when Exception
          raise val
        else
          val
        end
      end

      private def try_accept_nonblock : {::TCPSocket, ::Socket::Address}?
        fd_and_addr = CML::Socket.try_accept_fd(@server)
        return nil unless fd_and_addr
        fd, address = fd_and_addr
        blocking = {% if flag?(:win32) %} nil {% else %} ::Socket.get_blocking(fd) {% end %}
        ::Socket.set_blocking(fd, blocking) unless blocking.nil?
        socket = ::TCPSocket.from_handle(fd, family: @server.family, type: @server.type, protocol: @server.protocol, blocking: blocking)
        socket.sync = @server.sync?
        {socket, address}
      end

      private def store_result(value : {::TCPSocket, ::Socket::Address})
        @result.set(value)
        @ready.set(true)
      end
    end

    # Socket connect event (SML/NJ connectEvt semantics)
    class ConnectEvent < Event(Nil)
      @socket : ::Socket
      @address : ::Socket::Address
      @nack_evt : Event(Nil)?
      @ready = AtomicFlag.new
      @cancel_flag = AtomicFlag.new
      @result = Slot(Exception | Nil).new
      @started = false
      @start_mtx = CML::Sync::Mutex.new

      def initialize(@socket, @address, @nack_evt = nil)
      end

      def poll : EventStatus(Nil)
        if @ready.get
          CML.trace "ConnectEvent.poll ready", tag: "socket"
          return Enabled(Nil).new(priority: 0, value: fetch_result)
        end

        if CML::Socket.connect_nonblock(@socket, @address)
          CML.trace "ConnectEvent.poll immediate", tag: "socket"
          store_result(nil)
          return Enabled(Nil).new(priority: 0, value: nil)
        end

        Blocked(Nil).new do |tid, next_fn|
          start_once(tid)
          next_fn.call
        end
      end

      protected def force_impl : EventGroup(Nil)
        BaseGroup(Nil).new(-> : EventStatus(Nil) { poll })
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
            CML.trace "ConnectEvent.start_once begin", tag: "socket"
            loop do
              break if @cancel_flag.get
              CML.sync(CML::PrimitiveIO.wait_writable_evt(@socket, @nack_evt))
              if CML::Socket.connect_nonblock(@socket, @address)
                CML.trace "ConnectEvent.start_once connected", tag: "socket"
                deliver(nil, tid)
                break
              end
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

      private def deliver(value : Exception | Nil, tid : TransactionId)
        return if @cancel_flag.get
        @result.set(value)
        @ready.set(true)
        tid.try_commit_and_resume
      end

      private def fetch_result : Nil
        case val = @result.get
        when Exception
          raise val
        else
          val
        end
      end

      private def store_result(value : Nil)
        @result.set(value)
        @ready.set(true)
      end
    end

  # Unix domain socket accept
  class UnixAcceptEvent < Event({::UNIXSocket, ::Socket::Address})
    @server : ::UNIXServer
    @nack_evt : Event(Nil)?
    @ready = AtomicFlag.new
    @cancel_flag = AtomicFlag.new
    @result = Slot(Exception | {::UNIXSocket, ::Socket::Address}).new
    @started = false
    @start_mtx = CML::Sync::Mutex.new

    def initialize(@server, @nack_evt = nil)
    end

    def poll : EventStatus({::UNIXSocket, ::Socket::Address})
      if @ready.get
        CML.trace "UnixAcceptEvent.poll ready", tag: "socket"
        return Enabled({::UNIXSocket, ::Socket::Address}).new(priority: 0, value: fetch_result)
      end

      if result = try_accept_nonblock
        CML.trace "UnixAcceptEvent.poll immediate", tag: "socket"
        store_result(result)
        return Enabled({::UNIXSocket, ::Socket::Address}).new(priority: 0, value: result)
      end

      Blocked({::UNIXSocket, ::Socket::Address}).new do |tid, next_fn|
        start_once(tid)
        next_fn.call
      end
    end

    protected def force_impl : EventGroup({::UNIXSocket, ::Socket::Address})
      BaseGroup({::UNIXSocket, ::Socket::Address}).new(-> : EventStatus({::UNIXSocket, ::Socket::Address}) { poll })
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
          CML.trace "UnixAcceptEvent.start_once begin", tag: "socket"
          while wait_until_readable(@server)
            break if @cancel_flag.get
            if result = try_accept_nonblock
              CML.trace "UnixAcceptEvent.start_once accepted", tag: "socket"
              deliver(result, tid)
              break
            end
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

    private def deliver(value : Exception | {::UNIXSocket, ::Socket::Address}, tid : TransactionId)
      return if @cancel_flag.get
      @result.set(value)
      @ready.set(true)
      tid.try_commit_and_resume
    end

    private def fetch_result : {::UNIXSocket, ::Socket::Address}
      case val = @result.get
      when Exception
        raise val
      else
        val
      end
    end

    private def try_accept_nonblock : {::UNIXSocket, ::Socket::Address}?
      fd_and_addr = CML::Socket.try_accept_fd(@server)
      return nil unless fd_and_addr
      fd, address = fd_and_addr
      blocking = {% if flag?(:win32) %} nil {% else %} ::Socket.get_blocking(fd) {% end %}
      ::Socket.set_blocking(fd, blocking) unless blocking.nil?
      socket = ::UNIXSocket.from_handle(fd, type: @server.type, path: @server.path, blocking: blocking)
      socket.sync = @server.sync?
      {socket, address}
    end

    private def store_result(value : {::UNIXSocket, ::Socket::Address})
      @result.set(value)
      @ready.set(true)
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

        if result = try_recv_nonblock
          store_result(result)
          return Enabled(Bytes).new(priority: 0, value: result)
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
            loop do
              break if @cancel_flag.get
              CML.sync(CML::PrimitiveIO.wait_readable_evt(@socket, @nack_evt))
              buffer = Bytes.new(@length)
              bytes = LibC.recv(@socket.fd, buffer, @length, @flags)
              if bytes < 0
                errno = Errno.value
                if errno == Errno::EAGAIN || errno == Errno::EWOULDBLOCK
                  # Not ready yet, wait and retry.
                  next
                else
                  raise IO::Error.from_os_error("recv", errno)
                end
              end
              deliver(buffer[0, bytes.to_i32], tid)
              break
            end
          rescue ex : Exception
            deliver(ex, tid)
          end
        end

        start_nack_watcher(tid)
      end

      private def try_recv_nonblock : Bytes?
        buffer = Bytes.new(@length)
        bytes = LibC.recv(@socket.fd, buffer, @length, CML::Socket.nonblock_flags(@flags))
        if bytes < 0
          errno = Errno.value
          return nil if errno == Errno::EAGAIN || errno == Errno::EWOULDBLOCK || errno == Errno::EINTR
          raise IO::Error.from_os_error("recv", errno)
        end
        buffer[0, bytes.to_i32]
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

      private def store_result(value : Bytes)
        @result.set(value)
        @ready.set(true)
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

        if result = try_send_nonblock
          store_result(result)
          return Enabled(Int32).new(priority: 0, value: result)
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
            CML.trace "SendEvent.start_once loop", @socket, tag: "socket"
            loop do
              break if @cancel_flag.get
              CML.sync(CML::PrimitiveIO.wait_writable_evt(@socket, @nack_evt))
              bytes = LibC.send(@socket.fd, @data, @data.size, @flags)
              if bytes < 0
                errno = Errno.value
                if errno == Errno::EAGAIN || errno == Errno::EWOULDBLOCK
                  next
                else
                  raise IO::Error.from_os_error("send", errno)
                end
              end
              deliver(bytes.to_i32, tid)
              break
            end
          rescue ex : Exception
            deliver(ex, tid)
          end
        end

        start_nack_watcher(tid)
      end

      private def try_send_nonblock : Int32?
        bytes = LibC.send(@socket.fd, @data, @data.size, CML::Socket.nonblock_flags(@flags))
        if bytes < 0
          errno = Errno.value
          return nil if errno == Errno::EAGAIN || errno == Errno::EWOULDBLOCK || errno == Errno::EINTR
          raise IO::Error.from_os_error("send", errno)
        end
        bytes.to_i32
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

      private def store_result(value : Int32)
        @result.set(value)
        @ready.set(true)
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

          if result = try_send_nonblock
            store_result(result)
            return Enabled(Int32).new(priority: 0, value: result)
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
              loop do
                break if @cancel_flag.get
                CML.sync(CML::PrimitiveIO.wait_writable_evt(@socket, @nack_evt))
                bytes_sent = send_once(@flags)
                next unless bytes_sent
                deliver(bytes_sent, tid)
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

        private def send_once(flags : Int32) : Int32?
          if @host && @port
            addr = ::Socket::IPAddress.new(@host.not_nil!, @port.not_nil!)
            bytes = LibC.sendto(@socket.fd, @data, @data.size, flags, addr.to_unsafe, addr.size.to_u32)
          else
            bytes = LibC.send(@socket.fd, @data, @data.size, flags)
          end
          if bytes < 0
            errno = Errno.value
            return nil if errno == Errno::EAGAIN || errno == Errno::EWOULDBLOCK || errno == Errno::EINTR
            raise IO::Error.from_os_error("send", errno)
          end
          bytes.to_i32
        end

        private def try_send_nonblock : Int32?
          send_once(CML::Socket.nonblock_flags(@flags))
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

        private def store_result(value : Int32)
          @result.set(value)
          @ready.set(true)
        end
      end

      class RecvEvent < Event({Bytes, ::Socket::Address})
        @socket : ::UDPSocket
        @max : Int32
        @flags : Int32
        @nack_evt : Event(Nil)?
        @ready = AtomicFlag.new
        @cancel_flag = AtomicFlag.new
        @result = Slot(Exception | {Bytes, ::Socket::Address}).new
        @started = false
        @start_mtx = CML::Sync::Mutex.new

        def initialize(@socket, @max, flags : Int32 = 0, @nack_evt = nil)
          @flags = flags
        end

        def poll : EventStatus({Bytes, ::Socket::Address})
          if @ready.get
            return Enabled({Bytes, ::Socket::Address}).new(priority: 0, value: fetch_result)
          end

          if result = try_recv_nonblock
            store_result(result)
            return Enabled({Bytes, ::Socket::Address}).new(priority: 0, value: result)
          end

          Blocked({Bytes, ::Socket::Address}).new do |tid, next_fn|
            start_once(tid)
            next_fn.call
          end
        end

        protected def force_impl : EventGroup({Bytes, ::Socket::Address})
          BaseGroup({Bytes, ::Socket::Address}).new(-> : EventStatus({Bytes, ::Socket::Address}) { poll })
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
              loop do
                break if @cancel_flag.get
                CML.sync(CML::PrimitiveIO.wait_readable_evt(@socket, @nack_evt))
                buffer = Bytes.new(@max)
                bytes_read, addr = @socket.receive(buffer)
                deliver({buffer[0, bytes_read], addr}, tid)
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

        private def deliver(value : Exception | {Bytes, ::Socket::Address}, tid : TransactionId)
          return if @cancel_flag.get
          @result.set(value)
          @ready.set(true)
          tid.try_commit_and_resume
        end

        private def fetch_result : {Bytes, ::Socket::Address}
          case val = @result.get
          when Exception
            raise val
          else
            val
          end
        end

        private def try_recv_nonblock : {Bytes, ::Socket::Address}?
          buffer = Bytes.new(@max)
          addr = uninitialized LibC::SockaddrStorage
          addr_len = LibC::SocklenT.new(sizeof(LibC::SockaddrStorage))
          bytes = LibC.recvfrom(@socket.fd, buffer, @max, CML::Socket.nonblock_flags(@flags), pointerof(addr).as(LibC::Sockaddr*), pointerof(addr_len))
          if bytes < 0
            errno = Errno.value
            return nil if errno == Errno::EAGAIN || errno == Errno::EWOULDBLOCK || errno == Errno::EINTR
            raise IO::Error.from_os_error("recvfrom", errno)
          end
          address = ::Socket::Address.from(pointerof(addr).as(LibC::Sockaddr*), addr_len)
          {buffer[0, bytes.to_i32], address}
        end

        private def store_result(value : {Bytes, ::Socket::Address})
          @result.set(value)
          @ready.set(true)
        end
      end

      def self.send_evt(socket : ::UDPSocket, data : Bytes, host : String? = nil, port : Int32? = nil, flags : Int32 = 0) : Event(Int32)
        CML.with_nack do |nack|
          SendEvent.new(socket, data, host, port, flags, nack)
        end
      end

      def self.send_vec_evt(socket : ::UDPSocket, data : Bytes, host : String? = nil, port : Int32? = nil, flags : Int32 = 0) : Event(Int32)
        send_evt(socket, data, host, port, flags)
      end

      def self.recv_evt(socket : ::UDPSocket, max : Int32, flags : Int32 = 0) : Event({Bytes, ::Socket::Address})
        CML.with_nack do |nack|
          RecvEvent.new(socket, max, flags, nack)
        end
      end

      def self.recv_vec_evt(socket : ::UDPSocket, max : Int32, flags : Int32 = 0) : Event(Bytes)
        CML.wrap(recv_evt(socket, max, flags)) do |(bytes, _addr)|
          bytes
        end
      end

      def self.recv_evt(socket : ::UDPSocket, max : Int32, flags : InFlags) : Event({Bytes, ::Socket::Address})
        recv_evt(socket, max, CML::Socket.in_flags_to_int(flags))
      end

      def self.recv_vec_evt(socket : ::UDPSocket, max : Int32, flags : InFlags) : Event(Bytes)
        recv_vec_evt(socket, max, CML::Socket.in_flags_to_int(flags))
      end

      def self.send_evt(socket : ::UDPSocket, data : Bytes, flags : OutFlags, host : String? = nil, port : Int32? = nil) : Event(Int32)
        send_evt(socket, data, host, port, CML::Socket.out_flags_to_int(flags))
      end

      def self.send_vec_evt(socket : ::UDPSocket, data : Bytes, flags : OutFlags, host : String? = nil, port : Int32? = nil) : Event(Int32)
        send_evt(socket, data, host, port, CML::Socket.out_flags_to_int(flags))
      end

      def self.recv_vec_from_evt(socket : ::UDPSocket, max : Int32, flags : Int32 = 0) : Event({Bytes, ::Socket::Address})
        recv_evt(socket, max, flags)
      end

      def self.recv_vec_from_evt(socket : ::UDPSocket, max : Int32, flags : InFlags) : Event({Bytes, ::Socket::Address})
        recv_evt(socket, max, flags)
      end

      def self.recv_arr_from_evt(socket : ::UDPSocket, buffer : Bytes, flags : Int32 = 0) : Event({Int32, ::Socket::Address})
        CML.wrap(recv_evt(socket, buffer.size, flags)) do |(bytes, addr)|
          bytes.copy_to(buffer)
          {bytes.size, addr}
        end
      end

      def self.recv_arr_evt(socket : ::UDPSocket, buffer : Bytes, flags : Int32 = 0) : Event(Int32)
        CML.wrap(recv_evt(socket, buffer.size, flags)) do |(bytes, _addr)|
          bytes.copy_to(buffer)
          bytes.size
        end
      end

      def self.recv_arr_from_evt(socket : ::UDPSocket, buffer : Bytes, flags : InFlags) : Event({Int32, ::Socket::Address})
        recv_arr_from_evt(socket, buffer, CML::Socket.in_flags_to_int(flags))
      end

      def self.recv_arr_evt(socket : ::UDPSocket, buffer : Bytes, flags : InFlags) : Event(Int32)
        recv_arr_evt(socket, buffer, CML::Socket.in_flags_to_int(flags))
      end

      def self.send_evt(socket : Socket::DatagramSocket, data : Bytes, host : String? = nil, port : Int32? = nil, flags : Int32 = 0) : Event(Int32)
        send_evt(socket.inner, data, host, port, flags)
      end

      def self.send_vec_evt(socket : Socket::DatagramSocket, data : Bytes, host : String? = nil, port : Int32? = nil, flags : Int32 = 0) : Event(Int32)
        send_evt(socket.inner, data, host, port, flags)
      end

      def self.recv_evt(socket : Socket::DatagramSocket, max : Int32, flags : Int32 = 0) : Event({Bytes, ::Socket::Address})
        recv_evt(socket.inner, max, flags)
      end

      def self.recv_vec_evt(socket : Socket::DatagramSocket, max : Int32, flags : Int32 = 0) : Event(Bytes)
        recv_vec_evt(socket.inner, max, flags)
      end

      def self.recv_evt(socket : Socket::DatagramSocket, max : Int32, flags : InFlags) : Event({Bytes, ::Socket::Address})
        recv_evt(socket.inner, max, flags)
      end

      def self.recv_vec_evt(socket : Socket::DatagramSocket, max : Int32, flags : InFlags) : Event(Bytes)
        recv_vec_evt(socket.inner, max, flags)
      end

      def self.send_evt(socket : Socket::DatagramSocket, data : Bytes, flags : OutFlags, host : String? = nil, port : Int32? = nil) : Event(Int32)
        send_evt(socket.inner, data, flags, host, port)
      end

      def self.send_vec_evt(socket : Socket::DatagramSocket, data : Bytes, flags : OutFlags, host : String? = nil, port : Int32? = nil) : Event(Int32)
        send_evt(socket.inner, data, flags, host, port)
      end

      def self.recv_vec_from_evt(socket : Socket::DatagramSocket, max : Int32, flags : Int32 = 0) : Event({Bytes, ::Socket::Address})
        recv_evt(socket.inner, max, flags)
      end

      def self.recv_vec_from_evt(socket : Socket::DatagramSocket, max : Int32, flags : InFlags) : Event({Bytes, ::Socket::Address})
        recv_evt(socket.inner, max, flags)
      end

      def self.recv_arr_from_evt(socket : Socket::DatagramSocket, buffer : Bytes, flags : Int32 = 0) : Event({Int32, ::Socket::Address})
        recv_arr_from_evt(socket.inner, buffer, flags)
      end

      def self.recv_arr_evt(socket : Socket::DatagramSocket, buffer : Bytes, flags : Int32 = 0) : Event(Int32)
        recv_arr_evt(socket.inner, buffer, flags)
      end

      def self.recv_arr_from_evt(socket : Socket::DatagramSocket, buffer : Bytes, flags : InFlags) : Event({Int32, ::Socket::Address})
        recv_arr_from_evt(socket.inner, buffer, flags)
      end

      def self.recv_arr_evt(socket : Socket::DatagramSocket, buffer : Bytes, flags : InFlags) : Event(Int32)
        recv_arr_evt(socket.inner, buffer, flags)
      end
    end

    def self.accept_evt(server : ::TCPServer) : Event({::TCPSocket, ::Socket::Address})
      CML.with_nack { |nack| AcceptEvent.new(server, nack) }
    end

    def self.accept_evt(server : Socket::PassiveSocket) : Event({::TCPSocket, ::Socket::Address})
      accept_evt(server.inner)
    end

    def self.connect_evt(socket : ::Socket, address : ::Socket::Address) : Event(Nil)
      CML.with_nack { |nack| ConnectEvent.new(socket, address, nack) }
    end

    def self.connect_evt(socket : SocketWrapper, address : ::Socket::Address) : Event(Nil)
      connect_evt(socket.inner, address)
    end

    def self.accept_evt(server : ::UNIXServer) : Event({::UNIXSocket, ::Socket::Address})
      CML.with_nack { |nack| UnixAcceptEvent.new(server, nack) }
    end

    def self.accept_evt(server : Socket::UnixPassiveSocket) : Event({::UNIXSocket, ::Socket::Address})
      accept_evt(server.inner)
    end

    def self.unix_connect_evt(path : String) : Event(::UNIXSocket)
      CML.with_nack { |nack| UnixConnectEvent.new(path, nack) }
    end

    def self.recv_evt(socket : ::Socket, length : Int32, flags : Int32 = 0) : Event(Bytes)
      CML.with_nack { |nack| RecvEvent.new(socket, length, flags, nack) }
    end

    def self.recv_evt(socket : ::Socket, length : Int32, flags : InFlags) : Event(Bytes)
      recv_evt(socket, length, in_flags_to_int(flags))
    end

    def self.recv_vec_evt(socket : ::Socket, length : Int32, flags : Int32 = 0) : Event(Bytes)
      recv_evt(socket, length, flags)
    end

    def self.recv_vec_evt(socket : ::Socket, length : Int32, flags : InFlags) : Event(Bytes)
      recv_evt(socket, length, flags)
    end

    def self.recv_arr_evt(socket : ::Socket, buffer : Bytes, flags : Int32 = 0) : Event(Int32)
      CML.wrap(recv_evt(socket, buffer.size, flags)) do |bytes|
        bytes.copy_to(buffer)
        bytes.size
      end
    end

    def self.recv_arr_evt(socket : ::Socket, buffer : Bytes, flags : InFlags) : Event(Int32)
      recv_arr_evt(socket, buffer, in_flags_to_int(flags))
    end

    def self.send_vec_evt(socket : ::Socket, data : Bytes, flags : Int32 = 0) : Event(Int32)
      send_evt(socket, data, flags)
    end

    def self.send_vec_evt(socket : ::Socket, data : Bytes, flags : OutFlags) : Event(Int32)
      send_evt(socket, data, out_flags_to_int(flags))
    end

    def self.send_arr_evt(socket : ::Socket, buffer : Bytes, flags : Int32 = 0) : Event(Int32)
      send_evt(socket, buffer, flags)
    end

    def self.send_arr_evt(socket : ::Socket, buffer : Bytes, flags : OutFlags) : Event(Int32)
      send_evt(socket, buffer, out_flags_to_int(flags))
    end

    def self.send_evt(socket : ::Socket, data : Bytes, flags : Int32 = 0) : Event(Int32)
      CML.with_nack { |nack| SendEvent.new(socket, data, flags, nack) }
    end

    def self.send_evt(socket : ::Socket, data : Bytes, flags : OutFlags) : Event(Int32)
      send_evt(socket, data, out_flags_to_int(flags))
    end

    def self.recv_evt(socket : Socket::StreamSocket, length : Int32, flags : Int32 = 0) : Event(Bytes)
      recv_evt(socket.inner, length, flags)
    end

    def self.recv_evt(socket : Socket::StreamSocket, length : Int32, flags : InFlags) : Event(Bytes)
      recv_evt(socket.inner, length, flags)
    end

    def self.recv_vec_evt(socket : Socket::StreamSocket, length : Int32, flags : Int32 = 0) : Event(Bytes)
      recv_evt(socket.inner, length, flags)
    end

    def self.recv_vec_evt(socket : Socket::StreamSocket, length : Int32, flags : InFlags) : Event(Bytes)
      recv_evt(socket.inner, length, flags)
    end

    def self.recv_arr_evt(socket : Socket::StreamSocket, buffer : Bytes, flags : Int32 = 0) : Event(Int32)
      recv_arr_evt(socket.inner, buffer, flags)
    end

    def self.recv_arr_evt(socket : Socket::StreamSocket, buffer : Bytes, flags : InFlags) : Event(Int32)
      recv_arr_evt(socket.inner, buffer, flags)
    end

    def self.send_evt(socket : Socket::StreamSocket, data : Bytes, flags : Int32 = 0) : Event(Int32)
      send_evt(socket.inner, data, flags)
    end

    def self.send_evt(socket : Socket::StreamSocket, data : Bytes, flags : OutFlags) : Event(Int32)
      send_evt(socket.inner, data, flags)
    end

    def self.send_vec_evt(socket : Socket::StreamSocket, data : Bytes, flags : Int32 = 0) : Event(Int32)
      send_evt(socket.inner, data, flags)
    end

    def self.send_vec_evt(socket : Socket::StreamSocket, data : Bytes, flags : OutFlags) : Event(Int32)
      send_evt(socket.inner, data, flags)
    end

    def self.send_arr_evt(socket : Socket::StreamSocket, buffer : Bytes, flags : Int32 = 0) : Event(Int32)
      send_evt(socket.inner, buffer, flags)
    end

    def self.send_arr_evt(socket : Socket::StreamSocket, buffer : Bytes, flags : OutFlags) : Event(Int32)
      send_evt(socket.inner, buffer, flags)
    end

    def self.recv_evt(socket : Socket::UnixStreamSocket, length : Int32, flags : Int32 = 0) : Event(Bytes)
      recv_evt(socket.inner, length, flags)
    end

    def self.recv_evt(socket : Socket::UnixStreamSocket, length : Int32, flags : InFlags) : Event(Bytes)
      recv_evt(socket.inner, length, flags)
    end

    def self.recv_vec_evt(socket : Socket::UnixStreamSocket, length : Int32, flags : Int32 = 0) : Event(Bytes)
      recv_evt(socket.inner, length, flags)
    end

    def self.recv_vec_evt(socket : Socket::UnixStreamSocket, length : Int32, flags : InFlags) : Event(Bytes)
      recv_evt(socket.inner, length, flags)
    end

    def self.recv_arr_evt(socket : Socket::UnixStreamSocket, buffer : Bytes, flags : Int32 = 0) : Event(Int32)
      recv_arr_evt(socket.inner, buffer, flags)
    end

    def self.recv_arr_evt(socket : Socket::UnixStreamSocket, buffer : Bytes, flags : InFlags) : Event(Int32)
      recv_arr_evt(socket.inner, buffer, flags)
    end

    def self.send_evt(socket : Socket::UnixStreamSocket, data : Bytes, flags : Int32 = 0) : Event(Int32)
      send_evt(socket.inner, data, flags)
    end

    def self.send_evt(socket : Socket::UnixStreamSocket, data : Bytes, flags : OutFlags) : Event(Int32)
      send_evt(socket.inner, data, flags)
    end

    def self.send_vec_evt(socket : Socket::UnixStreamSocket, data : Bytes, flags : Int32 = 0) : Event(Int32)
      send_evt(socket.inner, data, flags)
    end

    def self.send_vec_evt(socket : Socket::UnixStreamSocket, data : Bytes, flags : OutFlags) : Event(Int32)
      send_evt(socket.inner, data, flags)
    end

    def self.send_arr_evt(socket : Socket::UnixStreamSocket, buffer : Bytes, flags : Int32 = 0) : Event(Int32)
      send_evt(socket.inner, buffer, flags)
    end

    def self.send_arr_evt(socket : Socket::UnixStreamSocket, buffer : Bytes, flags : OutFlags) : Event(Int32)
      send_evt(socket.inner, buffer, flags)
    end

    def self.recv_evt(socket : Socket::UnixDatagramSocket, length : Int32, flags : Int32 = 0) : Event(Bytes)
      recv_evt(socket.inner, length, flags)
    end

    def self.recv_evt(socket : Socket::UnixDatagramSocket, length : Int32, flags : InFlags) : Event(Bytes)
      recv_evt(socket.inner, length, flags)
    end

    def self.recv_vec_evt(socket : Socket::UnixDatagramSocket, length : Int32, flags : Int32 = 0) : Event(Bytes)
      recv_evt(socket.inner, length, flags)
    end

    def self.recv_vec_evt(socket : Socket::UnixDatagramSocket, length : Int32, flags : InFlags) : Event(Bytes)
      recv_evt(socket.inner, length, flags)
    end

    def self.recv_arr_evt(socket : Socket::UnixDatagramSocket, buffer : Bytes, flags : Int32 = 0) : Event(Int32)
      recv_arr_evt(socket.inner, buffer, flags)
    end

    def self.recv_arr_evt(socket : Socket::UnixDatagramSocket, buffer : Bytes, flags : InFlags) : Event(Int32)
      recv_arr_evt(socket.inner, buffer, flags)
    end

    def self.send_evt(socket : Socket::UnixDatagramSocket, data : Bytes, flags : Int32 = 0) : Event(Int32)
      send_evt(socket.inner, data, flags)
    end

    def self.send_evt(socket : Socket::UnixDatagramSocket, data : Bytes, flags : OutFlags) : Event(Int32)
      send_evt(socket.inner, data, flags)
    end

    def self.send_vec_evt(socket : Socket::UnixDatagramSocket, data : Bytes, flags : Int32 = 0) : Event(Int32)
      send_evt(socket.inner, data, flags)
    end

    def self.send_vec_evt(socket : Socket::UnixDatagramSocket, data : Bytes, flags : OutFlags) : Event(Int32)
      send_evt(socket.inner, data, flags)
    end

    def self.send_arr_evt(socket : Socket::UnixDatagramSocket, buffer : Bytes, flags : Int32 = 0) : Event(Int32)
      send_evt(socket.inner, buffer, flags)
    end

    def self.send_arr_evt(socket : Socket::UnixDatagramSocket, buffer : Bytes, flags : OutFlags) : Event(Int32)
      send_evt(socket.inner, buffer, flags)
    end
  end
end
