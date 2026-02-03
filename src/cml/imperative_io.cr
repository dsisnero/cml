module CML
  module ImperativeIO
    class Instream(T, V)
      @stream : StreamIO::Instream(T)
      @pos : Int64
      @peek : T?
      @has_peek = false
      @closed = false

      def initialize(@stream : StreamIO::Instream(T), pos : Int64 = 0)
        @pos = pos
      end

      def get_instream : StreamIO::Instream(T)
        @stream
      end

      def set_instream(stream : StreamIO::Instream(T)) : Nil
        @stream = stream
      end

      def get_pos_in : Int64
        @pos
      end

      def set_pos_in(pos : Int64) : Nil
        set_pos(pos)
      end

      def input1 : {T, Instream(T, V)}?
        return nil if @closed
        if @has_peek
          elem = @peek.not_nil!
          @has_peek = false
          @peek = nil
          @pos += elem_size(elem)
          return {elem, self}
        end

        elem = @stream.read_one
        return nil if elem.nil?
        @pos += elem_size(elem)
        {elem, self}
      end

      def input_n(n : Int32) : {V, Instream(T, V)}
        return {empty_vector, self} if n <= 0

        if @has_peek
          elem = @peek.not_nil!
          @has_peek = false
          @peek = nil
          rest = @stream.read_n(n - 1)
          vec = concat_vectors(elem_to_vector(elem), slice_to_vector(rest))
          @pos += vector_size(vec)
          return {vec, self}
        end

        slice = @stream.read_n(n)
        vec = slice_to_vector(slice)
        @pos += vector_size(vec)
        {vec, self}
      end

      def input : {V, Instream(T, V)}
        if @has_peek
          elem = @peek.not_nil!
          @has_peek = false
          @peek = nil
          slice = @stream.read_available
          vec = concat_vectors(elem_to_vector(elem), slice_to_vector(slice))
          @pos += vector_size(vec)
          return {vec, self}
        end

        slice = @stream.read_available
        vec = slice_to_vector(slice)
        @pos += vector_size(vec)
        {vec, self}
      end

      def input_all : {V, Instream(T, V)}
        if @has_peek
          elem = @peek.not_nil!
          @has_peek = false
          @peek = nil
          slice = @stream.read_all
          vec = concat_vectors(elem_to_vector(elem), slice_to_vector(slice))
          @pos += vector_size(vec)
          return {vec, self}
        end

        slice = @stream.read_all
        vec = slice_to_vector(slice)
        @pos += vector_size(vec)
        {vec, self}
      end

      def can_input(n : Int32) : Bool
        return true if n <= 0
        count = @has_peek ? 1 : 0
        if io = raw_io
          if io.responds_to?(:peek)
            peek_bytes = io.peek
            count += peek_bytes ? peek_bytes.size : 0
          end
        end
        count >= n
      end

      def lookahead : T?
        return @peek if @has_peek
        elem = @stream.read_one
        return nil if elem.nil?
        @peek = elem
        @has_peek = true
        elem
      end

      def close_in : Nil
        return if @closed
        @closed = true
        raw_io.try &.close
      end

      def end_of_stream : Bool
        return true if @closed
        return false if @has_peek
        if io = raw_io
          return true if io.closed?
          if io.responds_to?(:peek)
            bytes = io.peek
            return bytes.nil? || bytes.empty?
          end
        end
        false
      end

      def input1_evt : Event({T, Instream(T, V)}?)
        {% if T == Char %}
          CML.wrap(CML::StreamIO.input1_evt(@stream.as(StreamIO::TextInstream))) do |result|
            next nil if result.nil?
            elem, new_stream = result
            @stream = new_stream
            @pos += elem_size(elem)
            {elem, self}
          end
        {% elsif T == UInt8 %}
          CML.wrap(CML::StreamIO.input1_evt(@stream.as(StreamIO::BinInstream))) do |result|
            next nil if result.nil?
            elem, new_stream = result
            @stream = new_stream
            @pos += elem_size(elem)
            {elem, self}
          end
        {% else %}
          {% raise "ImperativeIO input1_evt supports only Char/String and UInt8/Bytes" %}
        {% end %}
      end

      def input_n_evt(n : Int32) : Event({V, Instream(T, V)})
        {% if T == Char %}
          CML.wrap(CML::StreamIO.input_n_evt(@stream.as(StreamIO::TextInstream), n)) do |(vec, new_stream)|
            @stream = new_stream
            @pos += vector_size(vec)
            {vec.as(V), self}
          end
        {% elsif T == UInt8 %}
          CML.wrap(CML::StreamIO.input_n_evt(@stream.as(StreamIO::BinInstream), n)) do |(vec, new_stream)|
            @stream = new_stream
            @pos += vector_size(vec)
            {vec.as(V), self}
          end
        {% else %}
          {% raise "ImperativeIO input_n_evt supports only Char/String and UInt8/Bytes" %}
        {% end %}
      end

      def input_evt : Event({V, Instream(T, V)})
        {% if T == Char %}
          CML.wrap(CML::StreamIO.input_evt(@stream.as(StreamIO::TextInstream))) do |(vec, new_stream)|
            @stream = new_stream
            @pos += vector_size(vec)
            {vec.as(V), self}
          end
        {% elsif T == UInt8 %}
          CML.wrap(CML::StreamIO.input_evt(@stream.as(StreamIO::BinInstream))) do |(vec, new_stream)|
            @stream = new_stream
            @pos += vector_size(vec)
            {vec.as(V), self}
          end
        {% else %}
          {% raise "ImperativeIO input_evt supports only Char/String and UInt8/Bytes" %}
        {% end %}
      end

      def input_all_evt : Event({V, Instream(T, V)})
        {% if T == Char %}
          CML.wrap(CML::StreamIO.input_all_evt(@stream.as(StreamIO::TextInstream))) do |(vec, new_stream)|
            @stream = new_stream
            @pos += vector_size(vec)
            {vec.as(V), self}
          end
        {% elsif T == UInt8 %}
          CML.wrap(CML::StreamIO.input_all_evt(@stream.as(StreamIO::BinInstream))) do |(vec, new_stream)|
            @stream = new_stream
            @pos += vector_size(vec)
            {vec.as(V), self}
          end
        {% else %}
          {% raise "ImperativeIO input_all_evt supports only Char/String and UInt8/Bytes" %}
        {% end %}
      end

      private def set_pos(pos : Int64)
        if io = raw_io
          begin
            io.pos = pos
          rescue
          end
        end
        @pos = pos
      end

      private def raw_io : IO?
        {% if T == Char %}
          @stream.as(StreamIO::TextInstream).raw_io
        {% elsif T == UInt8 %}
          @stream.as(StreamIO::BinInstream).raw_io
        {% else %}
          nil
        {% end %}
      end

      private def slice_to_vector(slice : Slice(T)) : V
        {% if T == Char %}
          String.build do |builder|
            slice.each { |ch| builder << ch }
          end.as(V)
        {% elsif T == UInt8 %}
          slice.as(V)
        {% else %}
          {% raise "ImperativeIO supports only Char/String and UInt8/Bytes" %}
        {% end %}
      end

      private def elem_to_vector(elem : T) : V
        {% if T == Char %}
          elem.to_s.as(V)
        {% elsif T == UInt8 %}
          Bytes[elem].as(V)
        {% else %}
          {% raise "ImperativeIO supports only Char/String and UInt8/Bytes" %}
        {% end %}
      end

      private def concat_vectors(left : V, right : V) : V
        {% if T == Char %}
          (left.as(String) + right.as(String)).as(V)
        {% elsif T == UInt8 %}
          l = left.as(Bytes)
          r = right.as(Bytes)
          combined = Bytes.new(l.size + r.size)
          combined[0, l.size].copy_from(l)
          combined[l.size, r.size].copy_from(r)
          combined.as(V)
        {% else %}
          {% raise "ImperativeIO supports only Char/String and UInt8/Bytes" %}
        {% end %}
      end

      private def vector_size(vec : V) : Int32
        {% if T == Char %}
          vec.as(String).bytesize
        {% elsif T == UInt8 %}
          vec.as(Bytes).size
        {% else %}
          0
        {% end %}
      end

      private def elem_size(elem : T) : Int32
        {% if T == Char %}
          elem.to_s.bytesize
        {% elsif T == UInt8 %}
          1
        {% else %}
          0
        {% end %}
      end

      private def empty_vector : V
        {% if T == Char %}
          "".as(V)
        {% elsif T == UInt8 %}
          Bytes.new(0).as(V)
        {% else %}
          {% raise "ImperativeIO supports only Char/String and UInt8/Bytes" %}
        {% end %}
      end
    end

    class Outstream(T, V)
      @stream : StreamIO::Outstream(T)
      @pos : Int64
      @closed = false

      def initialize(@stream : StreamIO::Outstream(T), pos : Int64 = 0)
        @pos = pos
      end

      def get_outstream : StreamIO::Outstream(T)
        @stream
      end

      def set_outstream(stream : StreamIO::Outstream(T)) : Nil
        @stream = stream
      end

      def get_pos_out : Int64
        @pos
      end

      def set_pos_out(pos : Int64) : Nil
        set_pos(pos)
      end

      def output(data : V) : Outstream(T, V)
        return self if @closed
        out = output_to_stream(data)
        @stream = out
        @pos += vector_size(data)
        self
      end

      def output1(elem : T) : Outstream(T, V)
        return self if @closed
        out = output1_to_stream(elem)
        @stream = out
        @pos += elem_size(elem)
        self
      end

      def flush_out : Outstream(T, V)
        return self if @closed
        flush_stream
        self
      end

      def close_out : Nil
        return if @closed
        @closed = true
        close_stream
      end

      private def set_pos(pos : Int64)
        if io = raw_io
          begin
            io.pos = pos
          rescue
          end
        end
        @pos = pos
      end

      private def raw_io : IO?
        {% if T == Char %}
          @stream.as(StreamIO::TextOutstream).raw_io
        {% elsif T == UInt8 %}
          @stream.as(StreamIO::BinOutstream).raw_io
        {% else %}
          nil
        {% end %}
      end

      private def output_to_stream(data : V) : StreamIO::Outstream(T)
        {% if T == Char %}
          @stream.as(StreamIO::TextOutstream).output(data.as(String))
        {% elsif T == UInt8 %}
          @stream.as(StreamIO::BinOutstream).output(data.as(Bytes))
        {% else %}
          {% raise "ImperativeIO output supports only Char/String and UInt8/Bytes" %}
        {% end %}
      end

      private def output1_to_stream(elem : T) : StreamIO::Outstream(T)
        {% if T == Char %}
          @stream.as(StreamIO::TextOutstream).output1(elem.as(Char))
        {% elsif T == UInt8 %}
          @stream.as(StreamIO::BinOutstream).output1(elem.as(UInt8))
        {% else %}
          {% raise "ImperativeIO output1 supports only Char/String and UInt8/Bytes" %}
        {% end %}
      end

      private def flush_stream
        {% if T == Char %}
          @stream.as(StreamIO::TextOutstream).flush_out
        {% elsif T == UInt8 %}
          @stream.as(StreamIO::BinOutstream).flush_out
        {% else %}
          nil
        {% end %}
      end

      private def close_stream
        {% if T == Char %}
          @stream.as(StreamIO::TextOutstream).close_out
        {% elsif T == UInt8 %}
          @stream.as(StreamIO::BinOutstream).close_out
        {% else %}
          nil
        {% end %}
      end

      private def vector_size(vec : V) : Int32
        {% if T == Char %}
          vec.as(String).bytesize
        {% elsif T == UInt8 %}
          vec.as(Bytes).size
        {% else %}
          0
        {% end %}
      end

      private def elem_size(elem : T) : Int32
        {% if T == Char %}
          elem.to_s.bytesize
        {% elsif T == UInt8 %}
          1
        {% else %}
          0
        {% end %}
      end
    end

    def self.mk_instream(stream : StreamIO::TextInstream) : Instream(Char, String)
      Instream(Char, String).new(stream)
    end

    def self.mk_instream(stream : StreamIO::BinInstream) : Instream(UInt8, Bytes)
      Instream(UInt8, Bytes).new(stream)
    end

    def self.get_instream(instream : Instream(T, V)) : StreamIO::Instream(T) forall T, V
      instream.get_instream
    end

    def self.set_instream(instream : Instream(T, V), stream : StreamIO::Instream(T)) : Nil forall T, V
      instream.set_instream(stream)
    end

    def self.mk_outstream(stream : StreamIO::TextOutstream) : Outstream(Char, String)
      Outstream(Char, String).new(stream)
    end

    def self.mk_outstream(stream : StreamIO::BinOutstream) : Outstream(UInt8, Bytes)
      Outstream(UInt8, Bytes).new(stream)
    end

    def self.get_outstream(outstream : Outstream(T, V)) : StreamIO::Outstream(T) forall T, V
      outstream.get_outstream
    end

    def self.set_outstream(outstream : Outstream(T, V), stream : StreamIO::Outstream(T)) : Nil forall T, V
      outstream.set_outstream(stream)
    end
  end
end
