module CML
  module PrimIO
    # Reader record equivalent for SML/NJ PRIM_IO.
    class Reader
      getter name : String
      getter chunk_size : Int32

      def initialize(
        @name : String,
        @chunk_size : Int32,
        @read_vec : Proc(Int32, Bytes),
        @read_arr : Proc(Bytes, Int32),
        @read_vec_evt : Proc(Int32, Event(Bytes)),
        @read_arr_evt : Proc(Bytes, Event(Int32)),
        @avail : Proc(Int32?),
        @get_pos : Proc(Int64?),
        @set_pos : Proc(Int64, Nil),
        @end_pos : Proc(Int64?),
        @verify_pos : Proc(Int64?),
        @close : Proc(Nil),
        @io_desc : Proc(Nil),
      )
      end

      def read_vec(n : Int32) : Bytes
        @read_vec.call(n)
      end

      def read_arr(buffer : Bytes) : Int32
        @read_arr.call(buffer)
      end

      def read_vec_evt(n : Int32) : Event(Bytes)
        @read_vec_evt.call(n)
      end

      def read_arr_evt(buffer : Bytes) : Event(Int32)
        @read_arr_evt.call(buffer).as(Event(Int32))
      end

      def avail : Int32?
        @avail.call
      end

      def get_pos : Int64?
        @get_pos.call
      end

      def set_pos(pos : Int64) : Nil
        @set_pos.call(pos)
      end

      def end_pos : Int64?
        @end_pos.call
      end

      def verify_pos : Int64?
        @verify_pos.call
      end

      def close : Nil
        @close.call
      end

      def io_desc : Nil
        @io_desc.call
      end
    end

    # Writer record equivalent for SML/NJ PRIM_IO.
    class Writer
      getter name : String
      getter chunk_size : Int32

      def initialize(
        @name : String,
        @chunk_size : Int32,
        @write_vec : Proc(Bytes, Int32),
        @write_arr : Proc(Bytes, Int32),
        @write_vec_evt : Proc(Bytes, Event(Int32)),
        @write_arr_evt : Proc(Bytes, Event(Int32)),
        @get_pos : Proc(Int64?),
        @set_pos : Proc(Int64, Nil),
        @end_pos : Proc(Int64?),
        @verify_pos : Proc(Int64?),
        @close : Proc(Nil),
        @io_desc : Proc(Nil),
      )
      end

      def write_vec(data : Bytes) : Int32
        @write_vec.call(data)
      end

      def write_arr(buffer : Bytes) : Int32
        @write_arr.call(buffer)
      end

      def write_vec_evt(data : Bytes) : Event(Int32)
        @write_vec_evt.call(data)
      end

      def write_arr_evt(buffer : Bytes) : Event(Int32)
        @write_arr_evt.call(buffer)
      end

      def get_pos : Int64?
        @get_pos.call
      end

      def set_pos(pos : Int64) : Nil
        @set_pos.call(pos)
      end

      def end_pos : Int64?
        @end_pos.call
      end

      def verify_pos : Int64?
        @verify_pos.call
      end

      def close : Nil
        @close.call
      end

      def io_desc : Nil
        @io_desc.call
      end
    end
  end

  module ChanIO
    # Channel-backed reader/writer adapters for PrimIO.
    private class ChannelReader
      @chan : CML::Chan(Bytes?)
      @buffer : Bytes = Bytes.empty
      @closed = false

      def initialize(@chan : CML::Chan(Bytes?), @name : String, @chunk_size : Int32)
      end

      def name : String
        @name
      end

      def chunk_size : Int32
        @chunk_size
      end

      def read_vec(n : Int32) : Bytes
        return Bytes.empty if @closed
        return take_from_buffer(n) if @buffer.size > 0

        val = CML.sync(@chan.recv_evt)
        return mark_closed if val.nil?
        take_from_bytes(val, n)
      end

      def read_vec_evt(n : Int32) : Event(Bytes)
        return CML.always(Bytes.empty) if @closed
        return CML.always(take_from_buffer(n)) if @buffer.size > 0

        CML.wrap(@chan.recv_evt) do |val|
          next mark_closed if val.nil?
          take_from_bytes(val, n)
        end
      end

      def read_arr(buffer : Bytes) : Int32
        data = read_vec(buffer.size)
        data.copy_to(buffer)
        data.size
      end

      def read_arr_evt(buffer : Bytes) : Event(Int32)
        CML.wrap(read_vec_evt(buffer.size)) do |data|
          data.copy_to(buffer)
          data.size
        end
      end

      def avail : Int32?
        return 0 if @closed
        return @buffer.size if @buffer.size > 0
        nil
      end

      def get_pos : Int64?
        nil
      end

      def set_pos(pos : Int64) : Nil
        nil
      end

      def end_pos : Int64?
        nil
      end

      def verify_pos : Int64?
        nil
      end

      def close : Nil
        @closed = true
      end

      private def mark_closed : Bytes
        @closed = true
        Bytes.empty
      end

      private def take_from_bytes(bytes : Bytes, n : Int32) : Bytes
        data = bytes.dup
        return data if data.size <= n
        head = data[0, n]
        @buffer = data[n, data.size - n]
        head
      end

      private def take_from_buffer(n : Int32) : Bytes
        return Bytes.empty if @buffer.size == 0
        if @buffer.size <= n
          data = @buffer
          @buffer = Bytes.empty
          return data
        end

        data = @buffer[0, n]
        @buffer = @buffer[n, @buffer.size - n]
        data
      end
    end

    private class ChannelWriter
      @chan : CML::Chan(Bytes?)
      @closed = false

      def initialize(@chan : CML::Chan(Bytes?), @name : String, @chunk_size : Int32)
      end

      def name : String
        @name
      end

      def chunk_size : Int32
        @chunk_size
      end

      def write_vec(data : Bytes) : Int32
        raise IO::Error.new("channel writer closed") if @closed
        payload = data.dup
        CML.sync(@chan.send_evt(payload))
        payload.size
      end

      def write_arr(buffer : Bytes) : Int32
        write_vec(buffer)
      end

      def write_vec_evt(data : Bytes) : Event(Int32)
        raise IO::Error.new("channel writer closed") if @closed
        payload = data.dup
        CML.wrap(@chan.send_evt(payload)) { payload.size }
      end

      def write_arr_evt(buffer : Bytes) : Event(Int32)
        write_vec_evt(buffer)
      end

      def get_pos : Int64?
        nil
      end

      def set_pos(pos : Int64) : Nil
        nil
      end

      def end_pos : Int64?
        nil
      end

      def verify_pos : Int64?
        nil
      end

      def close : Nil
        return if @closed
        @closed = true
        CML.sync(@chan.send_evt(nil))
      end
    end

    def self.mk_reader(chan : CML::Chan(Bytes?), name : String = "chan", chunk_size : Int32 = 4096) : CML::PrimIO::Reader
      adapter = ChannelReader.new(chan, name, chunk_size)
      CML::PrimIO::Reader.new(
        adapter.name,
        adapter.chunk_size,
        ->(n : Int32) { adapter.read_vec(n) },
        ->(buffer : Bytes) { adapter.read_arr(buffer) },
        ->(n : Int32) { adapter.read_vec_evt(n) },
        ->(buffer : Bytes) { adapter.read_arr_evt(buffer).as(Event(Int32)) },
        -> { adapter.avail },
        -> : Int64? { adapter.get_pos },
        ->(pos : Int64) { adapter.set_pos(pos) },
        -> : Int64? { adapter.end_pos },
        -> : Int64? { adapter.verify_pos },
        -> { adapter.close },
        -> { nil }
      )
    end

    def self.mk_writer(chan : CML::Chan(Bytes?), name : String = "chan", chunk_size : Int32 = 4096) : CML::PrimIO::Writer
      adapter = ChannelWriter.new(chan, name, chunk_size)
      CML::PrimIO::Writer.new(
        adapter.name,
        adapter.chunk_size,
        ->(data : Bytes) { adapter.write_vec(data) },
        ->(buffer : Bytes) { adapter.write_arr(buffer) },
        ->(data : Bytes) { adapter.write_vec_evt(data).as(Event(Int32)) },
        ->(buffer : Bytes) { adapter.write_arr_evt(buffer).as(Event(Int32)) },
        -> : Int64? { adapter.get_pos },
        ->(pos : Int64) { adapter.set_pos(pos) },
        -> : Int64? { adapter.end_pos },
        -> : Int64? { adapter.verify_pos },
        -> { adapter.close },
        -> { nil }
      )
    end
  end
end
