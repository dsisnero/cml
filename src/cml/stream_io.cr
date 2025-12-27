module CML
  # Generic input stream following SML/NJ CML_STREAM_IO semantics.
  # Represents a functional stream where reading returns a value and a new stream.
  # For text streams: T = Char, vector = String
  # For binary streams: T = UInt8, vector = Bytes

  module StreamIO
    # Generic input stream following SML/NJ CML_STREAM_IO semantics.
    # Represents a functional stream where reading returns a value and a new stream.
    # For text streams: T = Char, vector = String
    # For binary streams: T = UInt8, vector = Bytes
    class Instream(T)
      @io : IO

      # Wrap an existing IO as an input stream.
      def initialize(@io : IO)
      end

      # Get the underlying IO (for internal use)
      protected def io : IO
        @io
      end

      # Create a new stream sharing the same IO
      protected def dup : Instream(T)
        Instream(T).new(@io)
      end

      # Read a single element, returns nil on EOF.
      # Must be implemented by subclasses.
      def read_one : T?
        raise NotImplementedError.new("Instream(T)#read_one")
      end

      # Read up to n elements.
      def read_n(n : Int32) : Slice(T)
        raise NotImplementedError.new("Instream(T)#read_n")
      end

      # Read all available elements (non-blocking).
      def read_available : Slice(T)
        raise NotImplementedError.new("Instream(T)#read_available")
      end

      # Read all remaining elements until EOF.
      def read_all : Slice(T)
        raise NotImplementedError.new("Instream(T)#read_all")
      end
    end

    # Generic output stream following SML/NJ CML_STREAM_IO semantics.
    class Outstream(T)
      @io : IO

      def initialize(@io : IO)
      end

      protected def io : IO
        @io
      end

      protected def dup : Outstream(T)
        Outstream(T).new(@io)
      end
    end

    # Text input stream (Char elements, String vectors)
    class TextInstream < Instream(Char)
      # Event that reads one character
      class Input1Event < Event({Char, TextInstream}?)
        @instream : TextInstream
        @nack_evt : Event(Nil)?
        @ready = AtomicFlag.new
        @cancel_flag = AtomicFlag.new
        @result = Slot(Exception | {Char, TextInstream}?).new
        @started = false
        @start_mtx : Mutex
        @start_mtx = Mutex.new(:reentrant)

        def initialize(@instream, @nack_evt = nil)
        end

        def poll : EventStatus({Char, TextInstream}?)
          if @ready.get
            return Enabled({Char, TextInstream}?).new(priority: 0, value: fetch_result)
          end

          Blocked({Char, TextInstream}?).new do |tid, next_fn|
            start_once(tid)
            next_fn.call
          end
        end

        protected def force_impl : EventGroup({Char, TextInstream}?)
          BaseGroup({Char, TextInstream}?).new(-> : EventStatus({Char, TextInstream}?) { poll })
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
              delivered = false
              loop do
                break if @cancel_flag.get
                readable = wait_until_readable
                unless readable
                  # timeout, continue waiting
                  next
                end
                char = @instream.io.read_char
                if char.nil?
                  deliver(nil, tid)
                else
                  # Create new stream for continuation
                  new_stream = TextInstream.new(@instream.io)
                  deliver({char, new_stream}, tid)
                end
                delivered = true
                break
              end

              # If we never delivered (cancelled before readable)
              unless delivered
                deliver(nil, tid)
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

          if @instream.io.responds_to?(:wait_readable)
            begin
              readable = @instream.io.wait_readable(50.milliseconds, raise_if_closed: false)
              return readable
            rescue ex
              return true
            end
          end

          true
        end

        private def deliver(value : Exception | {Char, TextInstream}?, tid : TransactionId)
          return if @cancel_flag.get
          @result.set(value)
          @ready.set(true)
          tid.try_commit_and_resume
        end

        private def fetch_result : {Char, TextInstream}?
          case val = @result.get
          when Exception
            raise val
          else
            val
          end
        end
      end

      # Event that reads up to n characters
      class InputNEvent < Event({String, TextInstream})
        @instream : TextInstream
        @n : Int32
        @nack_evt : Event(Nil)?
        @ready = AtomicFlag.new
        @cancel_flag = AtomicFlag.new
        @result = Slot(Exception | {String, TextInstream}).new
        @started = false
        @start_mtx : Mutex
        @start_mtx = Mutex.new(:reentrant)

        def initialize(@instream, @n, @nack_evt = nil)
          raise ArgumentError.new("n must be non-negative") if n < 0
        end

        def poll : EventStatus({String, TextInstream})
          if @ready.get
            return Enabled({String, TextInstream}).new(priority: 0, value: fetch_result)
          end

          Blocked({String, TextInstream}).new do |tid, next_fn|
            start_once(tid)
            next_fn.call
          end
        end

        protected def force_impl : EventGroup({String, TextInstream})
          BaseGroup({String, TextInstream}).new(-> : EventStatus({String, TextInstream}) { poll })
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
              delivered = false
              while wait_until_readable
                break if @cancel_flag.get
                # Read exactly n characters
                builder = String::Builder.new
                remaining = @n
                io = @instream.io
                while remaining > 0
                  char = io.read_char
                  break if char.nil?
                  builder << char
                  remaining -= 1
                end
                result_str = builder.to_s
                # Create new stream for continuation
                new_stream = TextInstream.new(io)
                deliver({result_str, new_stream}, tid)
                delivered = true
                break
              end

              # If we never delivered (wait_until_readable was false or cancelled)
              # we're at EOF (not readable and won't become readable)
              unless delivered
                new_stream = TextInstream.new(@instream.io)
                deliver({"", new_stream}, tid)
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

          if @instream.io.responds_to?(:wait_readable)
            begin
              readable = @instream.io.wait_readable(50.milliseconds, raise_if_closed: false)
              return readable
            rescue ex
              return true
            end
          end

          true
        end

        private def deliver(value : Exception | {String, TextInstream}, tid : TransactionId)
          return if @cancel_flag.get
          @result.set(value)
          @ready.set(true)
          tid.try_commit_and_resume
        end

        private def fetch_result : {String, TextInstream}
          case val = @result.get
          when Exception
            raise val
          else
            val
          end
        end
      end

      # Event that reads available input
      class InputEvent < Event({String, TextInstream})
        @instream : TextInstream
        @nack_evt : Event(Nil)?
        @ready = AtomicFlag.new
        @cancel_flag = AtomicFlag.new
        @result = Slot(Exception | {String, TextInstream}).new
        @started = false
        @start_mtx : Mutex
        @start_mtx = Mutex.new(:reentrant)

        def initialize(@instream, @nack_evt = nil)
        end

        def poll : EventStatus({String, TextInstream})
          if @ready.get
            return Enabled({String, TextInstream}).new(priority: 0, value: fetch_result)
          end

          Blocked({String, TextInstream}).new do |tid, next_fn|
            start_once(tid)
            next_fn.call
          end
        end

        protected def force_impl : EventGroup({String, TextInstream})
          BaseGroup({String, TextInstream}).new(-> : EventStatus({String, TextInstream}) { poll })
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
              delivered = false
              loop do
                break if @cancel_flag.get
                readable = wait_until_readable
                unless readable
                  # timeout, continue waiting
                  next
                end
                # readable (or closed)
                io = @instream.io
                buffer = Bytes.new(4096)
                read_bytes = io.read(buffer)
                if read_bytes == 0
                  # EOF
                  deliver({"", TextInstream.new(io)}, tid)
                else
                  str = String.new(buffer[0, read_bytes])
                  new_stream = TextInstream.new(io)
                  deliver({str, new_stream}, tid)
                end
                delivered = true
                break
              end

              # If we never delivered (cancelled before readable)
              unless delivered
                new_stream = TextInstream.new(@instream.io)
                deliver({"", new_stream}, tid)
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

          if @instream.io.responds_to?(:wait_readable)
            begin
              readable = @instream.io.wait_readable(50.milliseconds, raise_if_closed: false)
              return readable
            rescue ex
              return true
            end
          end

          true
        end

        private def deliver(value : Exception | {String, TextInstream}, tid : TransactionId)
          return if @cancel_flag.get
          @result.set(value)
          @ready.set(true)
          tid.try_commit_and_resume
        end

        private def fetch_result : {String, TextInstream}
          case val = @result.get
          when Exception
            raise val
          else
            val
          end
        end
      end

      # Event that reads all remaining input
      class InputAllEvent < Event({String, TextInstream})
        @instream : TextInstream
        @nack_evt : Event(Nil)?
        @ready = AtomicFlag.new
        @cancel_flag = AtomicFlag.new
        @result = Slot(Exception | {String, TextInstream}).new
        @started = false
        @start_mtx : Mutex
        @start_mtx = Mutex.new(:reentrant)

        def initialize(@instream, @nack_evt = nil)
        end

        def poll : EventStatus({String, TextInstream})
          if @ready.get
            return Enabled({String, TextInstream}).new(priority: 0, value: fetch_result)
          end

          Blocked({String, TextInstream}).new do |tid, next_fn|
            start_once(tid)
            next_fn.call
          end
        end

        protected def force_impl : EventGroup({String, TextInstream})
          BaseGroup({String, TextInstream}).new(-> : EventStatus({String, TextInstream}) { poll })
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
              builder = String::Builder.new
              io = @instream.io
              chunk_buf = Bytes.new(4096)
              loop do
                break if @cancel_flag.get
                read_bytes = io.read(chunk_buf) rescue 0
                break if read_bytes == 0
                builder.write(chunk_buf[0, read_bytes])
              end
              result_str = builder.to_s
              # Create new stream (will be at EOF)
              new_stream = TextInstream.new(io)
              deliver({result_str, new_stream}, tid)
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

        private def deliver(value : Exception | {String, TextInstream}, tid : TransactionId)
          return if @cancel_flag.get
          @result.set(value)
          @ready.set(true)
          tid.try_commit_and_resume
        end

        private def fetch_result : {String, TextInstream}
          case val = @result.get
          when Exception
            raise val
          else
            val
          end
        end
      end
    end

    # Event constructors for text streams
    def self.input1_evt(instream : TextInstream) : Event({Char, TextInstream}?)
      CML.with_nack do |nack|
        TextInstream::Input1Event.new(instream, nack)
      end
    end

    def self.input_n_evt(instream : TextInstream, n : Int32) : Event({String, TextInstream})
      CML.with_nack do |nack|
        TextInstream::InputNEvent.new(instream, n, nack)
      end
    end

    def self.input_evt(instream : TextInstream) : Event({String, TextInstream})
      CML.with_nack do |nack|
        TextInstream::InputEvent.new(instream, nack)
      end
    end

    def self.input_all_evt(instream : TextInstream) : Event({String, TextInstream})
      CML.with_nack do |nack|
        TextInstream::InputAllEvent.new(instream, nack)
      end
    end

    # Create a text input stream from an IO
    def self.open_text_in(io : IO) : TextInstream
      TextInstream.new(io)
    end

    # Read a single character, returns nil on EOF.
    def read_one : Char?
      io.read_char
    end

    # Read up to n characters.
    def read_n(n : Int32) : String
      builder = String::Builder.new
      remaining = n
      while remaining > 0
        ch = io.read_char
        break if ch.nil?
        builder << ch
        remaining -= 1
      end
      builder.to_s
    end

    # Read all available characters (non-blocking).
    def read_available : String
      # TODO: implement non-blocking read
      builder = String::Builder.new
      loop do
        ch = io.read_char
        break if ch.nil?
        builder << ch
      end
      builder.to_s
    end

    # Read all remaining characters until EOF.
    def read_all : String
      builder = String::Builder.new
      loop do
        ch = io.read_char
        break if ch.nil?
        builder << ch
      end
      builder.to_s
    end
  end
end
