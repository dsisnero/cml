module CML
  module BinIO
    class Instream
      @io : ::IO?
      @chan : CML::Chan(Bytes?)?
      @buffer : Bytes = Bytes.empty
      @closed = false

      def initialize(@io : ::IO)
      end

      def initialize(@chan : CML::Chan(Bytes?))
        @io = nil
        @closed = false
      end

      def raw_io : ::IO?
        @io
      end

      def self.from_channel(chan : CML::Chan(Bytes?)) : Instream
        Instream.new(chan)
      end

      def input1 : {UInt8, Instream}?
        byte = read_byte_blocking
        return if byte.nil?
        {byte, self}
      end

      def input_n(n : Int32) : {Bytes, Instream}
        data = read_bytes_blocking(n)
        {data, self}
      end

      def input : {Bytes, Instream}
        {drain_available, self}
      end

      def input_all : {Bytes, Instream}
        chunks = [] of Bytes
        if @buffer.size > 0
          chunks << @buffer
          @buffer = Bytes.empty
        end
        if chan = @chan
          loop do
            val = CML.sync(chan.recv_evt)
            break if val.nil?
            chunks << val
          end
        else
          chunks << io.gets_to_end.to_slice
        end
        data = concat_chunks(chunks)
        {data, self}
      end

      def can_input(n : Int32) : Bool
        return true if @buffer.size >= n
        if io_ptr = @io
          if io_ptr.responds_to?(:peek)
            bytes = io_ptr.peek
            return @buffer.size + (bytes ? bytes.size : 0) >= n
          end
        end
        false
      end

      def close_in : Nil
        return if @closed
        @closed = true
        @io.try &.close
      end

      def end_of_stream : Bool
        return true if @closed
        return false if @buffer.size > 0
        if io_ptr = @io
          return true if io_ptr.closed?
          if io_ptr.responds_to?(:peek)
            bytes = io_ptr.peek
            return bytes.nil? || bytes.empty?
          end
        end
        false
      end

      def input1_evt : Event({UInt8, Instream}?)
        return CML.always(nil.as({UInt8, Instream}?)) if @closed
        return CML.always(input1) if @buffer.size > 0
        if chan = @chan
          CML.wrap(chan.recv_evt) do |val|
            next if val.nil?
            @buffer = val
            input1
          end
        else
          stream = CML::StreamIO.open_bin_in(@io.not_nil!)
          CML.wrap(CML::StreamIO.input1_evt(stream)) do |result|
            next if result.nil?
            byte, _ = result
            {byte, self}
          end
        end
      end

      def input_n_evt(n : Int32) : Event({Bytes, Instream})
        return CML.always(input_n(n)) if @buffer.size > 0
        if chan = @chan
          CML.wrap(chan.recv_evt) do |val|
            @buffer = val || Bytes.empty
            input_n(n)
          end
        else
          stream = CML::StreamIO.open_bin_in(@io.not_nil!)
          CML.wrap(CML::StreamIO.input_n_evt(stream, n)) do |(data, _)|
            {data, self}
          end
        end
      end

      def input_evt : Event({Bytes, Instream})
        return CML.always(input) if @buffer.size > 0
        if chan = @chan
          CML.wrap(chan.recv_evt) do |val|
            @buffer = val || Bytes.empty
            input
          end
        else
          stream = CML::StreamIO.open_bin_in(@io.not_nil!)
          CML.wrap(CML::StreamIO.input_evt(stream)) do |(data, _)|
            {data, self}
          end
        end
      end

      def input_all_evt : Event({Bytes, Instream})
        if chan = @chan
          CML.wrap(chan.recv_evt) do |val|
            if val.nil?
              {Bytes.empty, self}
            else
              @buffer = val
              input_all
            end
          end
        else
          stream = CML::StreamIO.open_bin_in(@io.not_nil!)
          CML.wrap(CML::StreamIO.input_all_evt(stream)) do |(data, _)|
            {data, self}
          end
        end
      end

      private def io : ::IO
        @io.not_nil!
      end

      private def read_byte_blocking : UInt8?
        return if @closed
        if @buffer.size > 0
          byte = @buffer[0]
          @buffer = @buffer[1, @buffer.size - 1]
          return byte
        end
        if chan = @chan
          val = CML.sync(chan.recv_evt)
          return if val.nil?
          @buffer = val
          return read_byte_blocking
        end
        io.read_byte
      end

      private def read_bytes_blocking(n : Int32) : Bytes
        return Bytes.empty if n <= 0
        builder = Bytes.new(n)
        idx = 0
        while idx < n
          byte = read_byte_blocking
          break if byte.nil?
          builder[idx] = byte
          idx += 1
        end
        builder[0, idx]
      end

      private def drain_available : Bytes
        if @buffer.size > 0
          data = @buffer
          @buffer = Bytes.empty
          return data
        end
        return Bytes.empty if @chan
        bytes = io.read_available
        bytes.empty? ? Bytes.empty : bytes
      end

      private def concat_chunks(chunks : Array(Bytes)) : Bytes
        total = chunks.sum(&.size)
        buffer = Bytes.new(total)
        offset = 0
        chunks.each do |chunk|
          chunk.copy_to(buffer + offset)
          offset += chunk.size
        end
        buffer
      end
    end

    class Outstream
      @io : ::IO?
      @chan : CML::Chan(Bytes?)?
      @closed = false

      def initialize(@io : ::IO)
      end

      def initialize(@chan : CML::Chan(Bytes?))
        @io = nil
        @closed = false
      end

      def raw_io : ::IO?
        @io
      end

      def self.from_channel(chan : CML::Chan(Bytes?)) : Outstream
        Outstream.new(chan)
      end

      def output(data : Bytes) : Outstream
        raise IO::Error.new("output on closed stream") if @closed
        if chan = @chan
          CML.sync(chan.send_evt(data))
        else
          io.write(data)
        end
        self
      end

      def output1(byte : UInt8) : Outstream
        output(Bytes[byte])
      end

      def output_substr(data : Bytes, start : Int32, len : Int32) : Outstream
        slice = data[start, len] || Bytes.empty
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
      Instream.new(File.open(path, "rb"))
    end

    def self.open_out(path : String) : Outstream
      Outstream.new(File.open(path, "wb"))
    end

    def self.open_append(path : String) : Outstream
      Outstream.new(File.open(path, "ab"))
    end

    def self.open_string(bytes : Bytes) : Instream
      Instream.new(IO::Memory.new(bytes))
    end

    def self.open_chan_in(chan : CML::Chan(Bytes?)) : Instream
      Instream.from_channel(chan)
    end

    def self.open_chan_out(chan : CML::Chan(Bytes?)) : Outstream
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

    def self.input1(instream : Instream) : {UInt8, Instream}?
      instream.input1
    end

    def self.input_n(instream : Instream, n : Int32) : {Bytes, Instream}
      instream.input_n(n)
    end

    def self.input(instream : Instream) : {Bytes, Instream}
      instream.input
    end

    def self.input_all(instream : Instream) : {Bytes, Instream}
      instream.input_all
    end

    def self.can_input(instream : Instream, n : Int32) : Bool
      instream.can_input(n)
    end

    def self.close_in(instream : Instream) : Nil
      instream.close_in
    end

    def self.end_of_stream(instream : Instream) : Bool
      instream.end_of_stream
    end

    def self.output(outstream : Outstream, data : Bytes) : Outstream
      outstream.output(data)
    end

    def self.output1(outstream : Outstream, byte : UInt8) : Outstream
      outstream.output1(byte)
    end

    def self.output_substr(outstream : Outstream, data : Bytes, start : Int32, len : Int32) : Outstream
      outstream.output_substr(data, start, len)
    end

    def self.flush_out(outstream : Outstream) : Outstream
      outstream.flush_out
    end

    def self.close_out(outstream : Outstream) : Nil
      outstream.close_out
    end

    def self.input1_evt(instream : Instream) : Event({UInt8, Instream}?)
      instream.input1_evt
    end

    def self.input_n_evt(instream : Instream, n : Int32) : Event({Bytes, Instream})
      instream.input_n_evt(n)
    end

    def self.input_evt(instream : Instream) : Event({Bytes, Instream})
      instream.input_evt
    end

    def self.input_all_evt(instream : Instream) : Event({Bytes, Instream})
      instream.input_all_evt
    end

    def self.get_instream(instream : Instream) : CML::StreamIO::BinInstream
      io = instream.raw_io
      raise ArgumentError.new("instream has no IO backing") unless io
      CML::StreamIO.open_bin_in(io)
    end

    def self.set_instream(instream : Instream, stream : CML::StreamIO::BinInstream) : Instream
      Instream.new(stream.raw_io)
    end

    def self.get_outstream(outstream : Outstream) : CML::StreamIO::BinOutstream
      io = outstream.raw_io
      raise ArgumentError.new("outstream has no IO backing") unless io
      CML::StreamIO.open_bin_out(io)
    end

    def self.set_outstream(outstream : Outstream, stream : CML::StreamIO::BinOutstream) : Outstream
      Outstream.new(stream.raw_io)
    end
  end
end
