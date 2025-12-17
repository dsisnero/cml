module CML
  module IOEvents
    # Event that reads a fixed number of bytes from an IO without blocking registration.
    # Uses select polling in a background fiber and respects nack cancellation.
    class ReadEvent < Event(Bytes)
      @io : ::IO
      @length : Int32
      @nack_evt : Event(Nil)?
      @ready = AtomicFlag.new
      @cancel_flag = AtomicFlag.new
      @result = Slot(Exception | Bytes).new
      @started = false
      @start_mtx = Mutex.new

      def initialize(@io, @length, @nack_evt = nil)
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
            while wait_until_readable
              break if @cancel_flag.get
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
            @cancel_flag.set(true)
            tid.try_cancel
          end
        end
      end

      private def wait_until_readable : Bool
        return false if @cancel_flag.get

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

    # Event that reads a full line (or nil on EOF) from an IO as an event.
    class ReadLineEvent < Event(String?)
      @io : ::IO
      @nack_evt : Event(Nil)?
      @ready = AtomicFlag.new
      @cancel_flag = AtomicFlag.new
      @result = Slot(Exception | String?).new
      @started = false
      @start_mtx = Mutex.new

      def initialize(@io, @nack_evt = nil)
      end

      def poll : EventStatus(String?)
        if @ready.get
          return Enabled(String?).new(priority: 0, value: fetch_result)
        end

        Blocked(String?).new do |tid, next_fn|
          start_once(tid)
          next_fn.call
        end
      end

      protected def force_impl : EventGroup(String?)
        BaseGroup(String?).new(-> : EventStatus(String?) { poll })
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
            while wait_until_readable
              break if @cancel_flag.get
              line = @io.gets(chomp: false)
              deliver(line, tid)
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

      private def wait_until_readable : Bool
        return false if @cancel_flag.get

        if @io.responds_to?(:wait_readable)
          begin
            return @io.wait_readable(50.milliseconds, raise_if_closed: false)
          rescue
            return true
          end
        end

        true
      end

      private def deliver(value : Exception | String?, tid : TransactionId)
        return if @cancel_flag.get
        @result.set(value)
        @ready.set(true)
        tid.try_commit_and_resume
      end

      private def fetch_result : String?
        case val = @result.get
        when Exception
          raise val
        else
          val
        end
      end
    end

    # Event that reads the entire IO until EOF.
    class ReadAllEvent < Event(String)
      @io : ::IO
      @nack_evt : Event(Nil)?
      @ready = AtomicFlag.new
      @cancel_flag = AtomicFlag.new
      @result = Slot(Exception | String).new
      @started = false
      @start_mtx = Mutex.new

      def initialize(@io, @nack_evt = nil)
      end

      def poll : EventStatus(String)
        if @ready.get
          return Enabled(String).new(priority: 0, value: fetch_result)
        end

        Blocked(String).new do |tid, next_fn|
          start_once(tid)
          next_fn.call
        end
      end

      protected def force_impl : EventGroup(String)
        BaseGroup(String).new(-> : EventStatus(String) { poll })
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
            buffer = String::Builder.new
            chunk_buf = Bytes.new(4096)
            loop do
              break if @cancel_flag.get
              read_bytes = @io.read(chunk_buf)
              break if read_bytes == 0
              buffer.write(chunk_buf[0, read_bytes])
            end
            deliver(buffer.to_s, tid)
          rescue ex : Exception
            deliver(ex, tid)
          end
        end

        start_nack_watcher(tid)
      end

      private def wait_until_readable : Bool
        return false if @cancel_flag.get

        if @io.responds_to?(:wait_readable)
          begin
            return @io.wait_readable(50.milliseconds, raise_if_closed: false)
          rescue
            return true
          end
        end

        true
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

      private def deliver(value : Exception | String, tid : TransactionId)
        return if @cancel_flag.get
        @result.set(value)
        @ready.set(true)
        tid.try_commit_and_resume
      end

      private def fetch_result : String
        case val = @result.get
        when Exception
          raise val
        else
          val
        end
      end
    end

    # Event that writes bytes to an IO once it is writable.
    class WriteEvent < Event(Int32)
      @io : ::IO
      @data : Bytes
      @nack_evt : Event(Nil)?
      @ready = AtomicFlag.new
      @cancel_flag = AtomicFlag.new
      @result = Slot(Exception | Int32).new
      @started = false
      @start_mtx = Mutex.new

      def initialize(@io, data : Bytes, @nack_evt = nil)
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
            while bytes_written < @data.size
              break if @cancel_flag.get
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

    # Event that flushes an IO once writable.
    class FlushEvent < Event(Nil)
      @io : ::IO
      @nack_evt : Event(Nil)?
      @ready = AtomicFlag.new
      @cancel_flag = AtomicFlag.new
      @started = false
      @start_mtx = Mutex.new

      def initialize(@io, @nack_evt = nil)
      end

      def poll : EventStatus(Nil)
        if @ready.get
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
            @io.wait_writable(50.milliseconds)
            @io.flush
            deliver(tid)
          rescue ex : Exception
            deliver_error(ex, tid)
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

      private def deliver(tid : TransactionId)
        return if @cancel_flag.get
        @ready.set(true)
        tid.try_commit_and_resume
      end

      private def deliver_error(ex : Exception, tid : TransactionId)
        return if @cancel_flag.get
        @ready.set(true)
        raise ex
      end
    end
  end

  # -----------------------
  # IO helper events
  # -----------------------

  # Event that reads up to `bytes` from an IO.
  def self.read_evt(io : ::IO, bytes : Int32) : Event(Bytes)
    with_nack do |nack|
      IOEvents::ReadEvent.new(io, bytes, nack)
    end
  end

  # Event that reads a single line (nil on EOF) from an IO.
  def self.read_line_evt(io : ::IO) : Event(String?)
    with_nack do |nack|
      IOEvents::ReadLineEvent.new(io, nack)
    end
  end

  # Event that reads entire contents of an IO until EOF.
  def self.read_all_evt(io : ::IO) : Event(String)
    with_nack do |nack|
      IOEvents::ReadAllEvent.new(io, nack)
    end
  end

  # Event that reads up to n bytes.
  def self.input_evt(io : ::IO, n : Int32) : Event(Bytes)
    read_evt(io, n)
  end

  # Event that reads a single line (alias for read_line_evt).
  def self.input_line_evt(io : ::IO) : Event(String?)
    read_line_evt(io)
  end

  # Event that writes bytes to an IO.
  def self.write_evt(io : ::IO, data : Bytes) : Event(Int32)
    with_nack do |nack|
      IOEvents::WriteEvent.new(io, data, nack)
    end
  end

  # Event that writes a line (appends '\n').
  def self.write_line_evt(io : ::IO, line : String) : Event(Int32)
    write_evt(io, "#{line}\n".to_slice)
  end

  # Event that flushes an IO.
  def self.flush_evt(io : ::IO) : Event(Nil)
    with_nack do |nack|
      IOEvents::FlushEvent.new(io, nack)
    end
  end
end
