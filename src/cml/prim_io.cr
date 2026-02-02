# Primitive IO abstraction layer for CML
#
# Provides a pluggable backend system for IO operations with two implementations:
# 1. EventLoopBackend - Direct integration with Crystal's EventLoop for maximum performance
# 2. IOEventedBackend - Compatibility backend using IO::Evented (current implementation)
#
# The backend is selected based on execution context and availability of EventLoop hooks.

require "./sync"
require "crystal/event_loop"
require "fiber/execution_context"

module CML
  module PrimitiveIO
    # Abstract backend for primitive IO operations
    abstract class Backend
      # Create an event that reads up to `bytes` from the IO
      abstract def read_evt(io : ::IO, bytes : Int32, nack_evt : Event(Nil)?) : Event(Bytes)

      # Create an event that writes `data` to the IO
      abstract def write_evt(io : ::IO, data : Bytes, nack_evt : Event(Nil)?) : Event(Int32)

      # Create an event that waits for the IO to become readable
      abstract def wait_readable_evt(io : ::IO, nack_evt : Event(Nil)?) : Event(Nil)

      # Create an event that waits for the IO to become writable
      abstract def wait_writable_evt(io : ::IO, nack_evt : Event(Nil)?) : Event(Nil)

      # Get the file descriptor for an IO if available
      protected def fd_for(io : ::IO) : Crystal::System::FileDescriptor?
        # Return the IO as a Crystal::System::FileDescriptor if it includes the module
        io.as?(Crystal::System::FileDescriptor)
      end
    end

    # Default backend that uses IO::Evented with polling (current implementation)
    class IOEventedBackend < Backend
      def read_evt(io : ::IO, bytes : Int32, nack_evt : Event(Nil)?) : Event(Bytes)
        CompatReadEvent.new(io, bytes, nack_evt)
      end

      def write_evt(io : ::IO, data : Bytes, nack_evt : Event(Nil)?) : Event(Int32)
        CompatWriteEvent.new(io, data, nack_evt)
      end

      def wait_readable_evt(io : ::IO, nack_evt : Event(Nil)?) : Event(Nil)
        WaitReadableEvent.new(io, nack_evt)
      end

      def wait_writable_evt(io : ::IO, nack_evt : Event(Nil)?) : Event(Nil)
        WaitWritableEvent.new(io, nack_evt)
      end
    end

    # Event that waits for an IO to become readable using IO#wait_readable
    class WaitReadableEvent < Event(Nil)
      @io : ::IO
      @nack_evt : Event(Nil)?
      @ready = AtomicFlag.new
      @cancel_flag = AtomicFlag.new
      @result = Slot(Exception | Nil).new
      @started = AtomicFlag.new

      def initialize(@io, @nack_evt = nil)
      end

      def poll : EventStatus(Nil)
        CML.trace "WaitReadableEvent.poll", @io, tag: "prim_io"
        if @ready.get_with_acquire
          CML.trace "WaitReadableEvent.poll ready", tag: "prim_io"
          return Enabled(Nil).new(priority: 0, value: fetch_result)
        end

        Blocked(Nil).new do |tid, next_fn|
          CML.trace "WaitReadableEvent.poll blocked", tid.id, tag: "prim_io"
          start_once(tid)
          next_fn.call
        end
      end

      protected def force_impl : EventGroup(Nil)
        BaseGroup(Nil).new(-> : EventStatus(Nil) { poll })
      end

      private def start_once(tid : TransactionId)
        CML.trace "WaitReadableEvent.start_once", tid.id, tag: "prim_io"
        return unless @started.compare_and_set(false, true)
        CML.trace "WaitReadableEvent.start_once spawned", tag: "prim_io"

        ::spawn do
          begin
            CML.trace "WaitReadableEvent.start_once wait", tag: "prim_io"
            wait_until_readable
            CML.trace "WaitReadableEvent.start_once waited", tag: "prim_io"
            deliver(nil, tid)
          rescue ex : Exception
            CML.trace "WaitReadableEvent.start_once rescue", ex, tag: "prim_io"
            deliver(ex, tid)
          end
        end

        start_nack_watcher(tid)
      end

      private def wait_until_readable : Bool
        CML.trace "WaitReadableEvent.wait_until_readable start", tag: "prim_io"

        loop do
          return false if @cancel_flag.get_with_acquire

          if @io.responds_to?(:wait_readable)
            begin
              # Use a short timeout so cancellation can be observed.
              CML.trace "WaitReadableEvent.wait_until_readable calling", tag: "prim_io"
              result = @io.wait_readable(50.milliseconds, raise_if_closed: false)
              CML.trace "WaitReadableEvent.wait_until_readable result", result, tag: "prim_io"
              return true if result
            rescue
              CML.trace "WaitReadableEvent.wait_until_readable rescued", tag: "prim_io"
              return true
            end
          else
            CML.trace "WaitReadableEvent.wait_until_readable fallback true", tag: "prim_io"
            return true
          end
        end
      end

      private def start_nack_watcher(tid : TransactionId)
        if nack = @nack_evt
          ::spawn do
            CML.sync(nack)
            @cancel_flag.set_with_release(true)
            tid.try_cancel
          end
        end
      end

      private def deliver(value : Exception | Nil, tid : TransactionId)
        return if @cancel_flag.get_with_acquire
        @result.set(value)
        @ready.set_with_release(true)
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
    end

    # Event that waits for an IO to become writable using IO#wait_writable
    class WaitWritableEvent < Event(Nil)
      @io : ::IO
      @nack_evt : Event(Nil)?
      @ready = AtomicFlag.new
      @cancel_flag = AtomicFlag.new
      @result = Slot(Exception | Nil).new
      @started = AtomicFlag.new

      def initialize(@io, @nack_evt = nil)
      end

      def poll : EventStatus(Nil)
        if @ready.get_with_acquire
          return Enabled(Nil).new(priority: 0, value: fetch_result)
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
        return unless @started.compare_and_set(false, true)

        ::spawn do
          begin
            wait_until_writable
            deliver(nil, tid)
          rescue ex : Exception
            deliver(ex, tid)
          end
        end

        start_nack_watcher(tid)
      end

      private def wait_until_writable : Bool
        loop do
          return false if @cancel_flag.get_with_acquire

          if @io.responds_to?(:wait_writable)
            begin
              return true if @io.wait_writable(50.milliseconds)
            rescue
              return true
            end
          else
            return true
          end
        end
      end

      private def start_nack_watcher(tid : TransactionId)
        if nack = @nack_evt
          ::spawn do
            CML.sync(nack)
            @cancel_flag.set_with_release(true)
            tid.try_cancel
          end
        end
      end

      private def deliver(value : Exception | Nil, tid : TransactionId)
        return if @cancel_flag.get_with_acquire
        @result.set(value)
        @ready.set_with_release(true)
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
    end

    # Compatibility read event using IO::Evented with polling
    class CompatReadEvent < Event(Bytes)
      @io : ::IO
      @length : Int32
      @nack_evt : Event(Nil)?
      @ready = AtomicFlag.new
      @cancel_flag = AtomicFlag.new
      @result = Slot(Exception | Bytes).new
      @started = AtomicFlag.new

      def initialize(@io, @length, @nack_evt = nil)
      end

      def poll : EventStatus(Bytes)
        if @ready.get_with_acquire
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
        return unless @started.compare_and_set(false, true)

        ::spawn do
          begin
            while wait_until_readable
              break if @cancel_flag.get_with_acquire
              buffer = Bytes.new(@length)
              read_bytes = @io.read(buffer)
              deliver(buffer[0, read_bytes], tid)
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
            @cancel_flag.set_with_release(true)
            tid.try_cancel
          end
        end
      end

      private def wait_until_readable : Bool
        return false if @cancel_flag.get_with_acquire

        if @io.responds_to?(:wait_readable)
          begin
            return @io.wait_readable(50.milliseconds, raise_if_closed: false)
          rescue
            return true
          end
        end

        true
      end

      private def deliver(value : Exception | Bytes, tid : TransactionId)
        return if @cancel_flag.get_with_acquire
        @result.set(value)
        @ready.set_with_release(true)
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

    # Compatibility write event using IO::Evented with polling
    class CompatWriteEvent < Event(Int32)
      @io : ::IO
      @data : Bytes
      @nack_evt : Event(Nil)?
      @ready = AtomicFlag.new
      @cancel_flag = AtomicFlag.new
      @result = Slot(Exception | Int32).new
      @started = AtomicFlag.new

      def initialize(@io, data : Bytes, @nack_evt = nil)
        @data = data.dup
      end

      def poll : EventStatus(Int32)
        if @ready.get_with_acquire
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
        return unless @started.compare_and_set(false, true)

        ::spawn do
          begin
            bytes_written = 0
            while bytes_written < @data.size
              break if @cancel_flag.get_with_acquire
              @io.wait_writable(50.milliseconds)
              slice = @data[bytes_written..]
              @io.write(slice)
              bytes_written += slice.size
            end
            deliver(bytes_written, tid)
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
            @cancel_flag.set_with_release(true)
            tid.try_cancel
          end
        end
      end

      private def deliver(value : Exception | Int32, tid : TransactionId)
        return if @cancel_flag.get_with_acquire
        @result.set(value)
        @ready.set_with_release(true)
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

    # Direct EventLoop backend for maximum performance
    class EventLoopBackend < Backend
      def read_evt(io : ::IO, bytes : Int32, nack_evt : Event(Nil)?) : Event(Bytes)
        DirectReadEvent.new(io, bytes, nack_evt)
      end

      def write_evt(io : ::IO, data : Bytes, nack_evt : Event(Nil)?) : Event(Int32)
        DirectWriteEvent.new(io, data, nack_evt)
      end

      def wait_readable_evt(io : ::IO, nack_evt : Event(Nil)?) : Event(Nil)
        DirectWaitReadableEvent.new(io, nack_evt)
      end

      def wait_writable_evt(io : ::IO, nack_evt : Event(Nil)?) : Event(Nil)
        DirectWaitWritableEvent.new(io, nack_evt)
      end
    end

    # Direct EventLoop event for reading
    class DirectReadEvent < Event(Bytes)
      @io : ::IO
      @bytes : Int32
      @nack_evt : Event(Nil)?
      @ready = AtomicFlag.new
      @cancel_flag = AtomicFlag.new
      @result = Slot(Exception | Bytes).new
      @started = AtomicFlag.new

      def initialize(io : ::IO, bytes : Int32, nack_evt : Event(Nil)?)
        @io = io
        @bytes = bytes
        @nack_evt = nack_evt
      end

      def poll : EventStatus(Bytes)
        if @ready.get_with_acquire
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
        return unless @started.compare_and_set(false, true)

        ::spawn do
          begin
            read_from_fd(tid)
          rescue ex : Exception
            deliver(ex, tid)
          end
        end

        start_nack_watcher(tid)
      end

      private def read_from_fd(tid : TransactionId)
        return if @cancel_flag.get_with_acquire

        # Use EventLoop's read method directly for maximum performance
        buffer = Bytes.new(@bytes)
        read_bytes = if @io.is_a?(::Socket)
                       Crystal::EventLoop.current.read(@io.as(::Socket), buffer)
                     elsif @io.is_a?(IO::FileDescriptor)
                       Crystal::EventLoop.current.read(@io.as(Crystal::System::FileDescriptor), buffer)
                     else
                       # Fall back to IO's read method for other IO types
                       @io.read(buffer)
                     end
        deliver(buffer[0, read_bytes], tid)
      end

      private def start_nack_watcher(tid : TransactionId)
        if nack = @nack_evt
          ::spawn do
            CML.sync(nack)
            @cancel_flag.set_with_release(true)
            tid.try_cancel
          end
        end
      end

      private def deliver(value : Exception | Bytes, tid : TransactionId)
        return if @cancel_flag.get_with_acquire
        @result.set(value)
        @ready.set_with_release(true)
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

      private def fd_for(io : ::IO)
        io.fd if io.responds_to?(:fd)
      end
    end

    # Direct EventLoop event for writing
    class DirectWriteEvent < Event(Int32)
      @io : ::IO
      @data : Bytes
      @nack_evt : Event(Nil)?
      @ready = AtomicFlag.new
      @cancel_flag = AtomicFlag.new
      @result = Slot(Exception | Int32).new
      @started = AtomicFlag.new

      def initialize(io : ::IO, data : Bytes, nack_evt : Event(Nil)?)
        @io = io
        @data = data.dup
        @nack_evt = nack_evt
      end

      def poll : EventStatus(Int32)
        if @ready.get_with_acquire
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
        return unless @started.compare_and_set(false, true)

        ::spawn do
          begin
            write_to_fd(tid)
          rescue ex : Exception
            deliver(ex, tid)
          end
        end

        start_nack_watcher(tid)
      end

      private def write_to_fd(tid : TransactionId)
        return if @cancel_flag.get_with_acquire

        # Use EventLoop's write method directly for maximum performance
        written = if @io.is_a?(::Socket)
                    Crystal::EventLoop.current.write(@io.as(::Socket), @data)
                  elsif @io.is_a?(IO::FileDescriptor)
                    Crystal::EventLoop.current.write(@io.as(Crystal::System::FileDescriptor), @data)
                  else
                    # Fall back to IO's write method for other IO types
                    @io.write(@data)
                    @data.size
                  end
        deliver(written, tid)
      end

      private def start_nack_watcher(tid : TransactionId)
        if nack = @nack_evt
          ::spawn do
            CML.sync(nack)
            @cancel_flag.set_with_release(true)
            tid.try_cancel
          end
        end
      end

      private def deliver(value : Exception | Int32, tid : TransactionId)
        return if @cancel_flag.get_with_acquire
        @result.set(value)
        @ready.set_with_release(true)
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

      private def fd_for(io : ::IO)
        io.fd if io.responds_to?(:fd)
      end
    end

    # Direct EventLoop event for waiting readable
    class DirectWaitReadableEvent < Event(Nil)
      @io : ::IO
      @nack_evt : Event(Nil)?
      @ready = AtomicFlag.new
      @cancel_flag = AtomicFlag.new
      @result = Slot(Exception | Nil).new
      @started = AtomicFlag.new

      def initialize(io : ::IO, nack_evt : Event(Nil)?)
        @io = io
        @nack_evt = nack_evt
      end

      def poll : EventStatus(Nil)
        if @ready.get_with_acquire
          return Enabled(Nil).new(priority: 0, value: fetch_result)
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
        CML.trace "DirectWaitReadableEvent.start_once", tid.id, tag: "prim_io"
        return unless @started.compare_and_set(false, true)
        CML.trace "DirectWaitReadableEvent.start_once spawned", tag: "prim_io"

        ::spawn do
          begin
            CML.trace "DirectWaitReadableEvent.start_once wait", tag: "prim_io"
            wait_readable(tid)
            CML.trace "DirectWaitReadableEvent.start_once waited", tag: "prim_io"
          rescue ex : Exception
            CML.trace "DirectWaitReadableEvent.start_once rescue", ex, tag: "prim_io"
            deliver(ex, tid)
          end
        end

        start_nack_watcher(tid)
      end

      private def wait_readable(tid : TransactionId)
        CML.trace "DirectWaitReadableEvent.wait_readable start", @io.class, tag: "prim_io"
        loop do
          return if @cancel_flag.get_with_acquire

          # Prefer IO's wait_readable when available; it integrates with evented IO.
          if @io.responds_to?(:wait_readable)
            CML.trace "DirectWaitReadableEvent.wait_readable generic", tag: "prim_io"
            return deliver(nil, tid) if @io.wait_readable(50.milliseconds, raise_if_closed: false)
          elsif @io.is_a?(::Socket)
            CML.trace "DirectWaitReadableEvent.wait_readable socket", tag: "prim_io"
            Crystal::EventLoop.current.wait_readable(@io.as(::Socket))
            return deliver(nil, tid)
          elsif @io.is_a?(IO::FileDescriptor)
            CML.trace "DirectWaitReadableEvent.wait_readable fd", tag: "prim_io"
            Crystal::EventLoop.current.wait_readable(@io.as(Crystal::System::FileDescriptor))
            return deliver(nil, tid)
          else
            CML.trace "DirectWaitReadableEvent.wait_readable no method", tag: "prim_io"
            return deliver(nil, tid)
          end
        end
      end

      private def start_nack_watcher(tid : TransactionId)
        if nack = @nack_evt
          ::spawn do
            CML.sync(nack)
            @cancel_flag.set_with_release(true)
            tid.try_cancel
          end
        end
      end

      private def deliver(value : Exception | Nil, tid : TransactionId)
        return if @cancel_flag.get_with_acquire
        @result.set(value)
        @ready.set_with_release(true)
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

      private def fd_for(io : ::IO)
        io.fd if io.responds_to?(:fd)
      end
    end

    # Direct EventLoop event for waiting writable
    class DirectWaitWritableEvent < Event(Nil)
      @io : ::IO
      @nack_evt : Event(Nil)?
      @ready = AtomicFlag.new
      @cancel_flag = AtomicFlag.new
      @result = Slot(Exception | Nil).new
      @started = AtomicFlag.new

      def initialize(io : ::IO, nack_evt : Event(Nil)?)
        @io = io
        @nack_evt = nack_evt
      end

      def poll : EventStatus(Nil)
        if @ready.get_with_acquire
          return Enabled(Nil).new(priority: 0, value: fetch_result)
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
        return unless @started.compare_and_set(false, true)

        ::spawn do
          begin
            wait_writable(tid)
          rescue ex : Exception
            deliver(ex, tid)
          end
        end

        start_nack_watcher(tid)
      end

      private def wait_writable(tid : TransactionId)
        loop do
          return if @cancel_flag.get_with_acquire

          # Prefer IO's wait_writable when available; it integrates with evented IO.
          if @io.responds_to?(:wait_writable)
            return deliver(nil, tid) if @io.wait_writable(50.milliseconds)
          elsif @io.is_a?(::Socket)
            Crystal::EventLoop.current.wait_writable(@io.as(::Socket))
            return deliver(nil, tid)
          elsif @io.is_a?(IO::FileDescriptor)
            Crystal::EventLoop.current.wait_writable(@io.as(Crystal::System::FileDescriptor))
            return deliver(nil, tid)
          else
            return deliver(nil, tid)
          end
        end
      end

      private def start_nack_watcher(tid : TransactionId)
        if nack = @nack_evt
          ::spawn do
            CML.sync(nack)
            @cancel_flag.set_with_release(true)
            tid.try_cancel
          end
        end
      end

      private def deliver(value : Exception | Nil, tid : TransactionId)
        return if @cancel_flag.get_with_acquire
        @result.set(value)
        @ready.set_with_release(true)
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

      private def fd_for(io : ::IO)
        io.fd if io.responds_to?(:fd)
      end
    end

    # Backend selection logic
    @@backend : Backend?

    # Singleton backend instances (initialized lazily)
    @@event_loop_backend : EventLoopBackend?
    @@io_evented_backend : IOEventedBackend?

    # Mutex for thread-safe backend initialization
    @@backend_init_mtx = CML::Sync.mutex

    # Get the current backend, selecting optimal one based on context
    def self.backend : Backend
      # If custom backend is set (e.g., for testing), use it
      if custom = @@backend
        return custom
      end

      # Otherwise, select optimal backend based on current context
      select_backend
    end

    # Set a custom backend (for testing)
    def self.backend=(backend : Backend?)
      @@backend = backend
    end

    # Get the EventLoopBackend singleton (thread-safe initialization)
    private def self.event_loop_backend : EventLoopBackend
      # Double-checked locking for thread-safe lazy initialization
      if backend = @@event_loop_backend
        return backend
      end

      @@backend_init_mtx.synchronize do
        @@event_loop_backend ||= EventLoopBackend.new
      end
    end

    # Get the IOEventedBackend singleton (thread-safe initialization)
    private def self.io_evented_backend : IOEventedBackend
      # Double-checked locking for thread-safe lazy initialization
      if backend = @@io_evented_backend
        return backend
      end

      @@backend_init_mtx.synchronize do
        @@io_evented_backend ||= IOEventedBackend.new
      end
    end

    # Select the optimal backend based on current execution context
    private def self.get_optimal_backend : Backend
      # Check if we're in a Parallel execution context (requires thread-safe backend)
      if in_parallel_context?
        # Use direct EventLoop backend for maximum performance in parallel contexts
        event_loop_backend
      else
        # Use compatibility backend for Isolated, Concurrent, or default contexts
        io_evented_backend
      end
    end

    # Check if current execution context is Parallel (multi-threaded)
    private def self.in_parallel_context? : Bool
      # Execution contexts require -Dpreview_mt -Dexecution_context flags
      {% if flag?(:preview_mt) && flag?(:execution_context) %}
        context = Fiber::ExecutionContext.current
        context.is_a?(Fiber::ExecutionContext::Parallel)
      {% else %}
        # Without execution contexts, assume single-threaded (not parallel)
        false
      {% end %}
    end

    # Select backend for a specific IO type
    private def self.backend_for(io : ::IO) : Backend
      # If custom backend is set (e.g., for testing), use it
      if custom = @@backend
        return custom
      end

      # EventLoopBackend currently has a bug with pipes after blocking read.
      # Use compatibility backend for non-socket IO until DirectWaitReadableEvent is fixed.
      # EventLoopBackend currently has a bug with pipes after blocking read.
      # Use compatibility backend for non-socket IO until DirectWaitReadableEvent is fixed.
      if io.is_a?(::Socket) && in_parallel_context?
        # Only use EventLoopBackend for sockets in parallel contexts
        event_loop_backend
      else
        io_evented_backend
      end
    end

    # Select the appropriate backend based on execution context and capabilities
    private def self.select_backend : Backend
      # First check if EventLoop is available at all
      unless Crystal::EventLoop.current?
        # No EventLoop available - must use compatibility backend
        return io_evented_backend
      end

      # EventLoop is available - select optimal backend based on context
      get_optimal_backend
    end

    # Helper methods that delegate to the current backend
    def self.read_evt(io : ::IO, bytes : Int32, nack_evt : Event(Nil)? = nil) : Event(Bytes)
      backend_for(io).read_evt(io, bytes, nack_evt)
    end

    def self.write_evt(io : ::IO, data : Bytes, nack_evt : Event(Nil)? = nil) : Event(Int32)
      backend_for(io).write_evt(io, data, nack_evt)
    end

    def self.wait_readable_evt(io : ::IO, nack_evt : Event(Nil)? = nil) : Event(Nil)
      backend_for(io).wait_readable_evt(io, nack_evt)
    end

    def self.wait_writable_evt(io : ::IO, nack_evt : Event(Nil)? = nil) : Event(Nil)
      backend_for(io).wait_writable_evt(io, nack_evt)
    end
  end

  # Redefine IO helper methods to use PrimitiveIO backend
  # Event that reads up to `bytes` from an IO.
  def self.read_evt(io : ::IO, bytes : Int32) : Event(Bytes)
    with_nack do |nack|
      PrimitiveIO.read_evt(io, bytes, nack)
    end
  end

  # Event that writes bytes to an IO.
  def self.write_evt(io : ::IO, data : Bytes) : Event(Int32)
    with_nack do |nack|
      PrimitiveIO.write_evt(io, data, nack)
    end
  end
end
