require "socket"
require "../ext/io_wait_readable"

module CML
  module Socket
    # TCP accept
    class AcceptEvent < Event(::TCPSocket)
      @server : ::TCPServer
      @nack_evt : Event(Nil)?
      @ready = AtomicFlag.new
      @cancel_flag = AtomicFlag.new
      @result = Slot(Exception | ::TCPSocket).new
      @started = false
      @start_mtx = Mutex.new

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
          io.wait_readable(50.milliseconds, raise_if_closed: false)
        rescue
          true
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
      @start_mtx = Mutex.new

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

    # Receive bytes from a socket using readiness polling.
    class RecvEvent < Event(Bytes)
      @socket : ::Socket
      @length : Int32
      @nack_evt : Event(Nil)?
      @ready = AtomicFlag.new
      @cancel_flag = AtomicFlag.new
      @result = Slot(Exception | Bytes).new
      @started = false
      @start_mtx = Mutex.new

      def initialize(@socket, @length, @nack_evt = nil)
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
            while wait_until_readable(@socket)
              break if @cancel_flag.get
              buffer = Bytes.new(@length)
              read_bytes = @socket.read(buffer)
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
      @nack_evt : Event(Nil)?
      @ready = AtomicFlag.new
      @cancel_flag = AtomicFlag.new
      @result = Slot(Exception | Int32).new
      @started = false
      @start_mtx = Mutex.new

      def initialize(@socket, data : Bytes, @nack_evt = nil)
        @data = data.dup
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
              @socket.write(slice)
              bytes_written += slice.size
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
        @nack_evt : Event(Nil)?
        @ready = AtomicFlag.new
        @cancel_flag = AtomicFlag.new
        @result = Slot(Exception | Int32).new
        @started = false
        @start_mtx = Mutex.new

        def initialize(@socket, data : Bytes, @host = nil, @port = nil, @nack_evt = nil)
          @data = data.dup
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
              bytes_sent = if @host && @port
                             addr = ::Socket::IPAddress.new(@host.not_nil!, @port.not_nil!)
                             @socket.send(@data, addr)
                           else
                             @socket.send(@data)
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
        @nack_evt : Event(Nil)?
        @ready = AtomicFlag.new
        @cancel_flag = AtomicFlag.new
        @result = Slot(Exception | {Bytes, ::Socket::IPAddress}).new
        @started = false
        @start_mtx = Mutex.new

        def initialize(@socket, @max, @nack_evt = nil)
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
            io.wait_readable(50.milliseconds, raise_if_closed: false)
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

      def self.send_evt(socket : ::UDPSocket, data : Bytes, host : String? = nil, port : Int32? = nil) : Event(Int32)
        CML.with_nack do |nack|
          SendEvent.new(socket, data, host, port, nack)
        end
      end

      def self.recv_evt(socket : ::UDPSocket, max : Int32) : Event({Bytes, ::Socket::IPAddress})
        CML.with_nack do |nack|
          RecvEvent.new(socket, max, nack)
        end
      end
    end

    def self.accept_evt(server : ::TCPServer) : Event(::TCPSocket)
      CML.with_nack { |nack| AcceptEvent.new(server, nack) }
    end

    def self.connect_evt(host : String, port : Int32) : Event(::TCPSocket)
      CML.with_nack { |nack| ConnectEvent.new(host, port, nack) }
    end

    def self.recv_evt(socket : ::Socket, length : Int32) : Event(Bytes)
      CML.with_nack { |nack| RecvEvent.new(socket, length, nack) }
    end

    def self.send_evt(socket : ::Socket, data : Bytes) : Event(Int32)
      CML.with_nack { |nack| SendEvent.new(socket, data, nack) }
    end
  end
end
