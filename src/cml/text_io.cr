module CML
  module TextIO
    class Instream
      @io : ::IO?
      @chan : CML::Chan(String?)?
      @buffer : String = ""
      @peek_char : Char?
      @has_peek = false
      @closed = false

      def initialize(@io : ::IO)
      end

      def initialize(@chan : CML::Chan(String?))
        @io = nil
        @buffer = ""
        @peek_char = nil
        @has_peek = false
        @closed = false
      end

      def raw_io : ::IO?
        @io
      end

      def self.from_channel(chan : CML::Chan(String?)) : Instream
        Instream.new(chan)
      end

      def input1 : {Char, Instream}?
        ch = read_char_blocking
        return if ch.nil?
        {ch, self}
      end

      def input_n(n : Int32) : {String, Instream}
        str = read_chars_blocking(n)
        {str, self}
      end

      def input : {String, Instream}
        if @has_peek
          ch = @peek_char.not_nil!
          @has_peek = false
          @peek_char = nil
          return {ch.to_s + drain_available, self}
        end
        {drain_available, self}
      end

      def input_all : {String, Instream}
        data = String::Builder.new
        if @has_peek
          data << @peek_char.not_nil!
          @has_peek = false
          @peek_char = nil
        end
        if @buffer.size > 0
          data << @buffer
          @buffer = ""
        end
        if chan = @chan
          loop do
            val = CML.sync(chan.recv_evt)
            break if val.nil?
            data << val
          end
        else
          data << io.gets_to_end
        end
        {data.to_s, self}
      end

      def input_line : {String, Instream}?
        line = String::Builder.new
        if @has_peek
          line << @peek_char.not_nil!
          @has_peek = false
          @peek_char = nil
        end
        if @buffer.size > 0
          line << @buffer
          if line.to_s.includes?('\n')
            line_str = split_line(line.to_s)
            return {line_str, self}
          end
          @buffer = ""
        end
        if chan = @chan
          loop do
            val = CML.sync(chan.recv_evt)
            return if val.nil? && line.empty?
            if val
              line << val
              if line.to_s.includes?('\n')
                line_str = split_line(line.to_s)
                return {line_str, self}
              end
            else
              return {line.to_s, self}
            end
          end
        else
          rest = io.gets(chomp: false)
          return if rest.nil? && line.empty?
          line << rest if rest
          return {line.to_s, self}
        end
      end

      def can_input(n : Int32) : Bool
        return true if available_count >= n
        if io_ptr = @io
          if io_ptr.responds_to?(:peek)
            bytes = io_ptr.peek
            return (available_count + (bytes ? bytes.size : 0)) >= n
          end
        end
        false
      end

      def lookahead : Char?
        return @peek_char if @has_peek
        ch = read_char_blocking
        if ch
          @peek_char = ch
          @has_peek = true
        end
        ch
      end

      def close_in : Nil
        return if @closed
        @closed = true
        @io.try &.close
      end

      def end_of_stream : Bool
        return true if @closed
        return false if @has_peek
        return false if @buffer.size > 0
        if io_ptr = @io
          return true if io_ptr.closed?
          if io_ptr.responds_to?(:peek)
            bytes = io_ptr.peek
            return bytes.nil? || bytes.empty?
          end
          return false
        end
        false
      end

      def input1_evt : Event({Char, Instream}?)
        return CML.always(nil.as({Char, Instream}?)) if @closed
        if @has_peek || @buffer.size > 0
          return CML.always(input1)
        end
        if chan = @chan
          CML.wrap(chan.recv_evt) do |val|
            next if val.nil?
            @buffer = val
            input1
          end
        else
          stream = CML::StreamIO.open_text_in(@io.not_nil!)
          CML.wrap(CML::StreamIO.input1_evt(stream)) do |result|
            next if result.nil?
            ch, _ = result
            {ch, self}
          end
        end
      end

      def input_n_evt(n : Int32) : Event({String, Instream})
        if @has_peek || @buffer.size > 0
          return CML.always(input_n(n))
        end
        if chan = @chan
          CML.wrap(chan.recv_evt) do |val|
            @buffer = val || ""
            input_n(n)
          end
        else
          stream = CML::StreamIO.open_text_in(@io.not_nil!)
          CML.wrap(CML::StreamIO.input_n_evt(stream, n)) do |(str, _stream2)|
            {str, self}
          end
        end
      end

      def input_evt : Event({String, Instream})
        if @has_peek || @buffer.size > 0
          return CML.always(input)
        end
        if chan = @chan
          CML.wrap(chan.recv_evt) do |val|
            @buffer = val || ""
            input
          end
        else
          stream = CML::StreamIO.open_text_in(@io.not_nil!)
          CML.wrap(CML::StreamIO.input_evt(stream)) do |(str, _stream2)|
            {str, self}
          end
        end
      end

      def input_all_evt : Event({String, Instream})
        if chan = @chan
          CML.wrap(chan.recv_evt) do |val|
            if val.nil?
              {"", self}
            else
              @buffer = val
              input_all
            end
          end
        else
          stream = CML::StreamIO.open_text_in(@io.not_nil!)
          CML.wrap(CML::StreamIO.input_all_evt(stream)) do |(str, _stream2)|
            {str, self}
          end
        end
      end

      private def io : ::IO
        @io.not_nil!
      end

      private def available_count : Int32
        count = 0
        count += 1 if @has_peek
        count += @buffer.size
        count
      end

      private def read_char_blocking : Char?
        return if @closed
        if @has_peek
          ch = @peek_char
          @has_peek = false
          @peek_char = nil
          return ch
        end
        if @buffer.size > 0
          return shift_buffer_char
        end
        if chan = @chan
          val = CML.sync(chan.recv_evt)
          return if val.nil?
          @buffer = val
          return shift_buffer_char
        end
        io.read_char
      end

      private def read_chars_blocking(n : Int32) : String
        builder = String::Builder.new
        while builder.bytesize < n
          ch = read_char_blocking
          break if ch.nil?
          builder << ch
        end
        builder.to_s
      end

      private def drain_available : String
        if @buffer.size > 0
          data = @buffer
          @buffer = ""
          return data
        end
        return "" if @chan
        bytes = io.read_available
        bytes.empty? ? "" : String.new(bytes)
      end

      private def shift_buffer_char : Char
        ch = @buffer[0]
        @buffer = @buffer[1, @buffer.size - 1]
        ch
      end

      private def split_line(str : String) : String
        idx = str.index('\n')
        return str unless idx
        remaining = str[(idx + 1)..-1]?
        @buffer = remaining || ""
        str[0..idx]
      end
    end

    class Outstream
      @io : ::IO?
      @chan : CML::Chan(String?)?
      @closed = false

      def initialize(@io : ::IO)
      end

      def initialize(@chan : CML::Chan(String?))
        @io = nil
        @closed = false
      end

      def raw_io : ::IO?
        @io
      end

      def self.from_channel(chan : CML::Chan(String?)) : Outstream
        Outstream.new(chan)
      end

      def output(data : String) : Outstream
        raise IO::Error.new("output on closed stream") if @closed
        if chan = @chan
          CML.sync(chan.send_evt(data))
        else
          io << data
        end
        self
      end

      def output1(ch : Char) : Outstream
        output(ch.to_s)
      end

      def output_substr(data : String, start : Int32, len : Int32) : Outstream
        slice = data[start, len] || ""
        output(slice)
      end

      def flush_out : Outstream
        io.try &.flush
        self
      end

      def close_out : Nil
        return if @closed
        @closed = true
        if chan = @chan
          CML.sync(chan.send_evt(nil))
        else
          io.try &.close
        end
      end

      private def io : ::IO
        @io.not_nil!
      end
    end

    def self.open_in(path : String) : Instream
      Instream.new(File.open(path, "r"))
    end

    def self.open_out(path : String) : Outstream
      Outstream.new(File.open(path, "w"))
    end

    def self.open_append(path : String) : Outstream
      Outstream.new(File.open(path, "a"))
    end

    def self.open_string(str : String) : Instream
      Instream.new(IO::Memory.new(str))
    end

    def self.open_chan_in(chan : CML::Chan(String?)) : Instream
      Instream.from_channel(chan)
    end

    def self.open_chan_out(chan : CML::Chan(String?)) : Outstream
      Outstream.from_channel(chan)
    end

    def self.std_in : Instream
      @@std_in ||= Instream.new(STDIN)
    end

    def self.std_out : Outstream
      @@std_out ||= Outstream.new(STDOUT)
    end

    def self.std_err : Outstream
      @@std_err ||= Outstream.new(STDERR)
    end

    def self.input1(instream : Instream) : {Char, Instream}?
      instream.input1
    end

    def self.input_n(instream : Instream, n : Int32) : {String, Instream}
      instream.input_n(n)
    end

    def self.input(instream : Instream) : {String, Instream}
      instream.input
    end

    def self.input_all(instream : Instream) : {String, Instream}
      instream.input_all
    end

    def self.input_line(instream : Instream) : {String, Instream}?
      instream.input_line
    end

    def self.can_input(instream : Instream, n : Int32) : Bool
      instream.can_input(n)
    end

    def self.lookahead(instream : Instream) : Char?
      instream.lookahead
    end

    def self.close_in(instream : Instream) : Nil
      instream.close_in
    end

    def self.end_of_stream(instream : Instream) : Bool
      instream.end_of_stream
    end

    def self.output(outstream : Outstream, data : String) : Outstream
      outstream.output(data)
    end

    def self.output1(outstream : Outstream, ch : Char) : Outstream
      outstream.output1(ch)
    end

    def self.output_substr(outstream : Outstream, data : String, start : Int32, len : Int32) : Outstream
      outstream.output_substr(data, start, len)
    end

    def self.flush_out(outstream : Outstream) : Outstream
      outstream.flush_out
    end

    def self.close_out(outstream : Outstream) : Nil
      outstream.close_out
    end

    def self.input1_evt(instream : Instream) : Event({Char, Instream}?)
      instream.input1_evt
    end

    def self.input_n_evt(instream : Instream, n : Int32) : Event({String, Instream})
      instream.input_n_evt(n)
    end

    def self.input_evt(instream : Instream) : Event({String, Instream})
      instream.input_evt
    end

    def self.input_all_evt(instream : Instream) : Event({String, Instream})
      instream.input_all_evt
    end

    def self.print(data : String) : Nil
      std_out.output(data)
      std_out.flush_out
    end

    def self.get_instream(instream : Instream) : CML::StreamIO::TextInstream
      io = instream.raw_io
      raise ArgumentError.new("instream has no IO backing") unless io
      CML::StreamIO.open_text_in(io)
    end

    def self.set_instream(instream : Instream, stream : CML::StreamIO::TextInstream) : Instream
      Instream.new(stream.raw_io)
    end

    def self.get_outstream(outstream : Outstream) : CML::StreamIO::TextOutstream
      io = outstream.raw_io
      raise ArgumentError.new("outstream has no IO backing") unless io
      CML::StreamIO.open_text_out(io)
    end

    def self.set_outstream(outstream : Outstream, stream : CML::StreamIO::TextOutstream) : Outstream
      Outstream.new(stream.raw_io)
    end
  end
end
