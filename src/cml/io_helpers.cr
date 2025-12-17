module CML
  # Simple IO adapter that reads strings from a channel.
  class ChannelInIO < IO
    @chan : Chan(String)
    @buffer = Bytes.empty
    @closed = false

    def initialize(@chan)
    end

    def read(slice : Bytes) : Int32
      return 0 if @closed

      refill_buffer if @buffer.empty?
      return 0 if @buffer.empty?

      count = Math.min(slice.size, @buffer.size)
      i = 0
      while i < count
        slice[i] = @buffer[i]
        i += 1
      end
      @buffer = @buffer[count..]
      count
    end

    def close
      @closed = true
    end

    def write(slice : Bytes) : Nil
      raise IO::Error.new("ChannelInIO is read-only")
    end

    private def refill_buffer
      return if @closed
      str = CML.sync(@chan.recv_evt)
      if str.empty?
        @buffer = Bytes.empty
        return
      end

      @buffer = Bytes.new(str.bytesize)
      str.to_slice.copy_to(@buffer)
    end
  end

  # IO adapter that writes strings to a channel.
  class ChannelOutIO < IO
    @chan : Chan(String)
    @closed = false

    def initialize(@chan)
    end

    def write(slice : Bytes) : Nil
      return if @closed
      return if slice.empty?

      CML.sync(@chan.send_evt(String.new(slice)))
    end

    def flush
    end

    def close
      @closed = true
    end

    def read(slice : Bytes) : Int32
      raise IO::Error.new("ChannelOutIO is write-only")
    end
  end

  def self.open_chan_in(chan : Chan(String)) : ChannelInIO
    ChannelInIO.new(chan)
  end

  def self.open_chan_out(chan : Chan(String)) : ChannelOutIO
    ChannelOutIO.new(chan)
  end

  # Convenience channel-backed event helpers
  def self.input_chan_evt(chan : Chan(String), n : Int32) : Event(Bytes)
    read_evt(open_chan_in(chan), n)
  end

  def self.input_chan_line_evt(chan : Chan(String)) : Event(String?)
    read_line_evt(open_chan_in(chan))
  end

  def self.output_chan_evt(chan : Chan(String), data : Bytes) : Event(Int32)
    write_evt(open_chan_out(chan), data)
  end
end
