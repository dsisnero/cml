module CML
  module IOEvents

    # Event that reads a full line (or nil on EOF) from an IO as an event.
    class ReadLineEvent < Event(String?)
      @io : ::IO
      @nack_evt : Event(Nil)?
      @ready = AtomicFlag.new
      @cancel_flag = AtomicFlag.new
      @result = Slot(Exception | String?).new
      @started = AtomicFlag.new

      def initialize(@io, @nack_evt = nil)
      end

      def poll : EventStatus(String?)
        CML.trace "ReadLineEvent.poll", @io, tag: "io"
        if @ready.get_with_acquire
          CML.trace "ReadLineEvent.poll ready", @ready.get, tag: "io"
          return Enabled(String?).new(priority: 0, value: fetch_result)
        end

        Blocked(String?).new do |tid, next_fn|
          CML.trace "ReadLineEvent.poll blocked", tid.id, tag: "io"
          start_once(tid)
          next_fn.call
        end
      end

      protected def force_impl : EventGroup(String?)
        BaseGroup(String?).new(-> : EventStatus(String?) { poll })
      end

      private def start_once(tid : TransactionId)
        CML.trace "ReadLineEvent.start_once", tid.id, tag: "io"
        return unless @started.compare_and_set(false, true)
        CML.trace "ReadLineEvent.start_once spawned", tag: "io"

        ::spawn do
          begin
            result = nil
            while wait_until_readable
              CML.trace "ReadLineEvent.wait_until_readable true", tag: "io"
              break if @cancel_flag.get_with_acquire
              result = @io.gets(chomp: false)
              CML.trace "ReadLineEvent.gets result", result.inspect, tag: "io"
              break
            end
            deliver(result, tid)
          rescue ex : Exception
            CML.trace "ReadLineEvent.start_once rescue", ex, tag: "io"
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
        CML.trace "ReadLineEvent.wait_until_readable start", tag: "io"
        return false if @cancel_flag.get_with_acquire

        begin
          # Use PrimitiveIO backend for waiting
          CML.trace "ReadLineEvent.wait_until_readable sync", tag: "io"
          CML.sync(CML::PrimitiveIO.wait_readable_evt(@io, @nack_evt))
          CML.trace "ReadLineEvent.wait_until_readable true", tag: "io"
          true
        rescue ex : Exception
          # IO closed or nack triggered
          CML.trace "ReadLineEvent.wait_until_readable rescue", ex, tag: "io"
          false
        end
      end

      private def deliver(value : Exception | String?, tid : TransactionId)
        return if @cancel_flag.get_with_acquire
        @result.set(value)
        @ready.set_with_release(true)
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
      @started = AtomicFlag.new

      def initialize(@io, @nack_evt = nil)
      end

      def poll : EventStatus(String)
        if @ready.get_with_acquire
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
        return unless @started.compare_and_set(false, true)

        ::spawn do
          begin
            buffer = String::Builder.new
            loop do
              break if @cancel_flag.get_with_acquire
              # Read chunk using PrimitiveIO backend
              chunk = CML.sync(CML::PrimitiveIO.read_evt(@io, 4096, @nack_evt))
              break if chunk.empty?  # EOF
              buffer.write(chunk)
            end
            deliver(buffer.to_s, tid)
          rescue ex : Exception
            deliver(ex, tid)
          end
        end

        start_nack_watcher(tid)
      end

      private def wait_until_readable : Bool
        CML.trace "ReadAllEvent.wait_until_readable start", tag: "io"
        return false if @cancel_flag.get_with_acquire

        begin
          # Use PrimitiveIO backend for waiting
          CML.trace "ReadAllEvent.wait_until_readable sync", tag: "io"
          CML.sync(CML::PrimitiveIO.wait_readable_evt(@io, @nack_evt))
          CML.trace "ReadAllEvent.wait_until_readable true", tag: "io"
          true
        rescue ex : Exception
          # IO closed or nack triggered
          CML.trace "ReadAllEvent.wait_until_readable rescue", ex, tag: "io"
          false
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

      private def deliver(value : Exception | String, tid : TransactionId)
        return if @cancel_flag.get_with_acquire
        @result.set(value)
        @ready.set_with_release(true)
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

    class FlushEvent < Event(Nil)
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
            CML.sync(CML::PrimitiveIO.wait_writable_evt(@io, @nack_evt))
            @io.flush
            deliver(nil, tid)
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
  end

  # -----------------------
  # IO helper events
  # -----------------------

  # Event that reads up to `bytes` from an IO.
  def self.read_evt(io : ::IO, bytes : Int32) : Event(Bytes)
    with_nack do |nack|
      PrimitiveIO.read_evt(io, bytes, nack)
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
      PrimitiveIO.write_evt(io, data, nack)
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
