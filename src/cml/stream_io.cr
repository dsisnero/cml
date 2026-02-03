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
      def raw_io : IO
        io
      end

      # Event that reads one character
      class Input1Event < Event({Char, TextInstream}?)
        @instream : TextInstream
        @nack_evt : Event(Nil)?
        @ready = AtomicFlag.new
        @cancel_flag = AtomicFlag.new
        @result = Slot(Exception | {Char, TextInstream}?).new
        @started = false
        @start_mtx : CML::Sync::Mutex
        @start_mtx = CML::Sync::Mutex.new(:reentrant)

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
                  # EOF
                  deliver(nil, tid)
                else
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

      # Event that reads all remaining input
      class InputAllEvent < Event({String, TextInstream})
        @instream : TextInstream
        @nack_evt : Event(Nil)?
        @ready = AtomicFlag.new
        @cancel_flag = AtomicFlag.new
        @result = Slot(Exception | {String, TextInstream}).new
        @started = false
        @start_mtx : CML::Sync::Mutex
        @start_mtx = CML::Sync::Mutex.new(:reentrant)

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

      # Event that reads exactly n characters
      class InputNEvent < Event({String, TextInstream})
        @instream : TextInstream
        @n : Int32
        @nack_evt : Event(Nil)?
        @ready = AtomicFlag.new
        @cancel_flag = AtomicFlag.new
        @result = Slot(Exception | {String, TextInstream}).new
        @started = false
        @start_mtx : CML::Sync::Mutex
        @start_mtx = CML::Sync::Mutex.new(:reentrant)

        def initialize(@instream, @n, @nack_evt = nil)
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
                io = @instream.io
                builder = String::Builder.new
                remaining = @n
                while remaining > 0
                  ch = io.read_char
                  break if ch.nil?
                  builder << ch
                  remaining -= 1
                end
                str = builder.to_s
                new_stream = TextInstream.new(io)
                deliver({str, new_stream}, tid)
                delivered = true
                break
              end

              # If we never delivered (cancelled before readable)
              unless delivered
                # Deliver empty string on cancellation
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

      # Event that reads available input (non-blocking)
      class InputEvent < Event({String, TextInstream})
        @instream : TextInstream
        @nack_evt : Event(Nil)?
        @ready = AtomicFlag.new
        @cancel_flag = AtomicFlag.new
        @result = Slot(Exception | {String, TextInstream}).new
        @started = false
        @start_mtx : CML::Sync::Mutex
        @start_mtx = CML::Sync::Mutex.new(:reentrant)

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
                io = @instream.io
                bytes = Bytes.empty
                if io.responds_to?(:peek)
                  peek_bytes = io.peek
                  if peek_bytes && !peek_bytes.empty?
                    bytes = Bytes.new(peek_bytes.size)
                    io.read_fully(bytes)
                  end
                end
                str = bytes.empty? ? "" : String.new(bytes)
                new_stream = TextInstream.new(io)
                deliver({str, new_stream}, tid)
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
    end

    # Binary input stream (UInt8 elements, Bytes vectors)
    class BinInstream < Instream(UInt8)
      def raw_io : IO
        io
      end

      class Input1Event < Event({UInt8, BinInstream}?)
        @instream : BinInstream
        @nack_evt : Event(Nil)?
        @ready = AtomicFlag.new
        @cancel_flag = AtomicFlag.new
        @result = Slot(Exception | {UInt8, BinInstream}?).new
        @started = false
        @start_mtx : CML::Sync::Mutex
        @start_mtx = CML::Sync::Mutex.new(:reentrant)

        def initialize(@instream, @nack_evt = nil)
        end

        def poll : EventStatus({UInt8, BinInstream}?)
          if @ready.get
            return Enabled({UInt8, BinInstream}?).new(priority: 0, value: fetch_result)
          end

          Blocked({UInt8, BinInstream}?).new do |tid, next_fn|
            start_once(tid)
            next_fn.call
          end
        end

        protected def force_impl : EventGroup({UInt8, BinInstream}?)
          BaseGroup({UInt8, BinInstream}?).new(-> : EventStatus({UInt8, BinInstream}?) { poll })
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
                readable = wait_until_readable
                unless readable
                  next
                end
                byte = @instream.io.read_byte
                if byte.nil?
                  deliver(nil, tid)
                else
                  deliver({byte, BinInstream.new(@instream.io)}, tid)
                end
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

        private def deliver(value : Exception | {UInt8, BinInstream}?, tid : TransactionId)
          return if @cancel_flag.get
          @result.set(value)
          @ready.set(true)
          tid.try_commit_and_resume
        end

        private def fetch_result : {UInt8, BinInstream}?
          case val = @result.get
          when Exception
            raise val
          else
            val
          end
        end
      end

      class InputNEvent < Event({Bytes, BinInstream})
        @instream : BinInstream
        @nack_evt : Event(Nil)?
        @ready = AtomicFlag.new
        @cancel_flag = AtomicFlag.new
        @result = Slot(Exception | {Bytes, BinInstream}).new
        @started = false
        @start_mtx : CML::Sync::Mutex
        @start_mtx = CML::Sync::Mutex.new(:reentrant)

        def initialize(@instream, @n, @nack_evt = nil)
        end

        def poll : EventStatus({Bytes, BinInstream})
          if @ready.get
            return Enabled({Bytes, BinInstream}).new(priority: 0, value: fetch_result)
          end

          Blocked({Bytes, BinInstream}).new do |tid, next_fn|
            start_once(tid)
            next_fn.call
          end
        end

        protected def force_impl : EventGroup({Bytes, BinInstream})
          BaseGroup({Bytes, BinInstream}).new(-> : EventStatus({Bytes, BinInstream}) { poll })
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
                readable = wait_until_readable
                unless readable
                  next
                end
                buffer = Bytes.new(@n)
                bytes_read = @instream.io.read(buffer)
                deliver({buffer[0, bytes_read], BinInstream.new(@instream.io)}, tid)
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

        private def deliver(value : Exception | {Bytes, BinInstream}, tid : TransactionId)
          return if @cancel_flag.get
          @result.set(value)
          @ready.set(true)
          tid.try_commit_and_resume
        end

        private def fetch_result : {Bytes, BinInstream}
          case val = @result.get
          when Exception
            raise val
          else
            val
          end
        end
      end

      class InputEvent < Event({Bytes, BinInstream})
        @instream : BinInstream
        @nack_evt : Event(Nil)?
        @ready = AtomicFlag.new
        @cancel_flag = AtomicFlag.new
        @result = Slot(Exception | {Bytes, BinInstream}).new
        @started = false
        @start_mtx : CML::Sync::Mutex
        @start_mtx = CML::Sync::Mutex.new(:reentrant)

        def initialize(@instream, @nack_evt = nil)
        end

        def poll : EventStatus({Bytes, BinInstream})
          if @ready.get
            return Enabled({Bytes, BinInstream}).new(priority: 0, value: fetch_result)
          end

          Blocked({Bytes, BinInstream}).new do |tid, next_fn|
            start_once(tid)
            next_fn.call
          end
        end

        protected def force_impl : EventGroup({Bytes, BinInstream})
          BaseGroup({Bytes, BinInstream}).new(-> : EventStatus({Bytes, BinInstream}) { poll })
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
                readable = wait_until_readable
                unless readable
                  next
                end
                bytes = @instream.io.read_available
                deliver({bytes, BinInstream.new(@instream.io)}, tid)
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

        private def deliver(value : Exception | {Bytes, BinInstream}, tid : TransactionId)
          return if @cancel_flag.get
          @result.set(value)
          @ready.set(true)
          tid.try_commit_and_resume
        end

        private def fetch_result : {Bytes, BinInstream}
          case val = @result.get
          when Exception
            raise val
          else
            val
          end
        end
      end

      class InputAllEvent < Event({Bytes, BinInstream})
        @instream : BinInstream
        @nack_evt : Event(Nil)?
        @ready = AtomicFlag.new
        @cancel_flag = AtomicFlag.new
        @result = Slot(Exception | {Bytes, BinInstream}).new
        @started = false
        @start_mtx : CML::Sync::Mutex
        @start_mtx = CML::Sync::Mutex.new(:reentrant)

        def initialize(@instream, @nack_evt = nil)
        end

        def poll : EventStatus({Bytes, BinInstream})
          if @ready.get
            return Enabled({Bytes, BinInstream}).new(priority: 0, value: fetch_result)
          end

          Blocked({Bytes, BinInstream}).new do |tid, next_fn|
            start_once(tid)
            next_fn.call
          end
        end

        protected def force_impl : EventGroup({Bytes, BinInstream})
          BaseGroup({Bytes, BinInstream}).new(-> : EventStatus({Bytes, BinInstream}) { poll })
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
              data = Bytes.empty
              loop do
                break if @cancel_flag.get
                readable = wait_until_readable
                unless readable
                  next
                end
                chunk = @instream.io.read_available
                break if chunk.empty?
                data = data + chunk
              end
              deliver({data, BinInstream.new(@instream.io)}, tid)
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

        private def deliver(value : Exception | {Bytes, BinInstream}, tid : TransactionId)
          return if @cancel_flag.get
          @result.set(value)
          @ready.set(true)
          tid.try_commit_and_resume
        end

        private def fetch_result : {Bytes, BinInstream}
          case val = @result.get
          when Exception
            raise val
          else
            val
          end
        end
      end
    end

    class BinOutstream < Outstream(UInt8)
      def raw_io : IO
        io
      end

      def output(data : Bytes) : BinOutstream
        io.write(data)
        BinOutstream.new(io)
      end

      def output1(byte : UInt8) : BinOutstream
        io.write(Bytes[byte])
        BinOutstream.new(io)
      end

      def flush_out : BinOutstream
        io.flush
        BinOutstream.new(io)
      end

      def close_out : Nil
        io.close
      end
    end

    def self.input1_evt(instream : BinInstream) : Event({UInt8, BinInstream}?)
      CML.with_nack do |nack|
        BinInstream::Input1Event.new(instream, nack)
      end
    end

    def self.input_n_evt(instream : BinInstream, n : Int32) : Event({Bytes, BinInstream})
      CML.with_nack do |nack|
        BinInstream::InputNEvent.new(instream, n, nack)
      end
    end

    def self.input_evt(instream : BinInstream) : Event({Bytes, BinInstream})
      CML.with_nack do |nack|
        BinInstream::InputEvent.new(instream, nack)
      end
    end

    def self.input_all_evt(instream : BinInstream) : Event({Bytes, BinInstream})
      CML.with_nack do |nack|
        BinInstream::InputAllEvent.new(instream, nack)
      end
    end

    def self.open_bin_in(io : IO) : BinInstream
      BinInstream.new(io)
    end

    def self.open_bin_out(io : IO) : BinOutstream
      BinOutstream.new(io)
    end

    # Text output stream (Char elements, String vectors)
    class TextOutstream < Outstream(Char)
      def raw_io : IO
        io
      end

      def output(data : String) : TextOutstream
        io << data
        TextOutstream.new(io)
      end

      def output1(ch : Char) : TextOutstream
        io << ch
        TextOutstream.new(io)
      end

      def flush_out : TextOutstream
        io.flush
        TextOutstream.new(io)
      end

      def close_out : Nil
        io.close
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

    # Create a text output stream from an IO
    def self.open_text_out(io : IO) : TextOutstream
      TextOutstream.new(io)
    end

    class TextInstream
      # Blocking input operations matching CML_STREAM_IO.
      def input1 : {Char, TextInstream}?
        ch = io.read_char
        return nil if ch.nil?
        {ch, TextInstream.new(io)}
      end

      def input_n(n : Int32) : {String, TextInstream}
        builder = String::Builder.new
        count = 0
        while count < n
          ch = io.read_char
          break if ch.nil?
          builder << ch
          count += 1
        end
        {builder.to_s, TextInstream.new(io)}
      end

      def input : {String, TextInstream}
        bytes = io.read_available
        str = bytes.empty? ? "" : String.new(bytes)
        {str, TextInstream.new(io)}
      end

      def input_all : {String, TextInstream}
        {io.gets_to_end, TextInstream.new(io)}
      end

      def close_in : Nil
        io.close
      end

      def end_of_stream : Bool
        return true if io.closed?
        if io.responds_to?(:peek)
          peek_bytes = io.peek
          return peek_bytes.nil? || peek_bytes.empty?
        end
        false
      end

      # Read a single character, returns nil on EOF.
      def read_one : Char?
        io.read_char
      end

      # Read up to n characters.
      def read_n(n : Int32) : Slice(Char)
        slice = Slice(Char).new(n)
        count = 0
        while count < n
          ch = io.read_char
          break if ch.nil?
          slice[count] = ch
          count += 1
        end
        slice[0, count]
      end

      # Read all available characters (non-blocking).
      def read_available : Slice(Char)
        bytes = io.read_available
        return Slice(Char).new(0) if bytes.empty?
        str = String.new(bytes)
        Slice(Char).new(str.size) { |i| str[i] }
      end

      # Read all remaining characters until EOF.
      def read_all : Slice(Char)
        chars = [] of Char
        loop do
          ch = io.read_char
          break if ch.nil?
          chars << ch
        end
        Slice(Char).new(chars.size) { |i| chars[i] }
      end
    end

    # Non-event StreamIO helpers
    def self.input1(instream : TextInstream) : {Char, TextInstream}?
      instream.input1
    end

    def self.input_n(instream : TextInstream, n : Int32) : {String, TextInstream}
      instream.input_n(n)
    end

    def self.input(instream : TextInstream) : {String, TextInstream}
      instream.input
    end

    def self.input_all(instream : TextInstream) : {String, TextInstream}
      instream.input_all
    end

    def self.end_of_stream(instream : TextInstream) : Bool
      instream.end_of_stream
    end

    def self.close_in(instream : TextInstream) : Nil
      instream.close_in
    end

    def self.output(outstream : TextOutstream, data : String) : TextOutstream
      outstream.output(data)
    end

    def self.output1(outstream : TextOutstream, ch : Char) : TextOutstream
      outstream.output1(ch)
    end

    def self.flush_out(outstream : TextOutstream) : TextOutstream
      outstream.flush_out
    end

    def self.close_out(outstream : TextOutstream) : Nil
      outstream.close_out
    end
  end
end
