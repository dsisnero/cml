module CML
  # Chapter-9-inspired Linda tuple-space port.
  #
  # This module mirrors the key layers from the SML implementation:
  # - Tuple/DataRep/NetMessage definitions
  # - TupleStore with hold/cancel/accept semantics
  # - Local tuple server + local proxy
  # - Output server and client-facing tuple-space operations
  # - Distributed request/reply proxies with join-time request-log replay
  module TupleLib
    private lib CSocket
      fun dup(fd : Int32) : Int32
    end

    struct ValAtom
      enum Kind
        Int
        String
        Bool
      end

      getter kind : Kind
      getter value : Int32 | String | Bool

      def initialize(@kind : Kind, @value : Int32 | String | Bool)
      end

      def self.int(value : Int32) : self
        new(Kind::Int, value)
      end

      def self.string(value : String) : self
        new(Kind::String, value)
      end

      def self.bool(value : Bool) : self
        new(Kind::Bool, value)
      end

      def ==(other : self)
        kind == other.kind && value == other.value
      end

      def hash(hasher)
        hasher = kind.hash(hasher)
        value.hash(hasher)
      end
    end

    struct PatAtom
      enum Kind
        IntLiteral
        StringLiteral
        BoolLiteral
        IntFormal
        StringFormal
        BoolFormal
        Wild
      end

      getter kind : Kind
      getter value : Int32 | String | Bool | Nil

      def initialize(@kind : Kind, @value : Int32 | String | Bool | Nil = nil)
      end

      def self.int_literal(value : Int32) : self
        new(Kind::IntLiteral, value)
      end

      def self.string_literal(value : String) : self
        new(Kind::StringLiteral, value)
      end

      def self.bool_literal(value : Bool) : self
        new(Kind::BoolLiteral, value)
      end

      def self.int_formal : self
        new(Kind::IntFormal)
      end

      def self.string_formal : self
        new(Kind::StringFormal)
      end

      def self.bool_formal : self
        new(Kind::BoolFormal)
      end

      def self.wild : self
        new(Kind::Wild)
      end
    end

    struct TupleRep(T)
      getter tag : ValAtom
      getter fields : Array(T)

      def initialize(@tag : ValAtom, @fields : Array(T))
      end
    end

    alias TupleValue = TupleRep(ValAtom)
    alias Template = TupleRep(PatAtom)

    module DataRep
      extend self

      def encode_values(values : Array(ValAtom)) : String
        io = IO::Memory.new
        values.each { |v| encode_val(io, v) }
        io << "e;"
        io.to_s
      end

      def encode_tuple(tuple : TupleValue) : String
        encode_values([tuple.tag] + tuple.fields)
      end

      def encode_template(template : Template) : String
        io = IO::Memory.new
        encode_val(io, template.tag)
        template.fields.each { |p| encode_pat(io, p) }
        io << "e;"
        io.to_s
      end

      def decode_values(data : String) : Array(ValAtom)
        i = 0
        values = [] of ValAtom
        while i < data.bytesize
          ch = data.byte_at(i).chr
          break if ch == 'e'
          val, next_i = decode_val(data, i)
          values << val
          i = next_i
        end
        values
      end

      def decode_tuple(data : String) : TupleValue
        vals = decode_values(data)
        raise "decode_tuple: empty tuple" if vals.empty?
        TupleValue.new(vals.first, vals[1..])
      end

      def decode_template(data : String) : Template
        i = 0
        tag, i = decode_val(data, i)
        pats = [] of PatAtom
        while i < data.bytesize
          ch = data.byte_at(i).chr
          break if ch == 'e'
          pat, next_i = decode_pat(data, i)
          pats << pat
          i = next_i
        end
        Template.new(tag, pats)
      end

      private def encode_val(io : IO, val : ValAtom)
        case val.kind
        when ValAtom::Kind::Int
          io << 'i' << val.value.as(Int32) << ';'
        when ValAtom::Kind::String
          s = val.value.as(String)
          io << 's' << s.bytesize << ':' << s << ';'
        when ValAtom::Kind::Bool
          io << (val.value.as(Bool) ? "B;" : "b;")
        end
      end

      private def encode_pat(io : IO, pat : PatAtom)
        case pat.kind
        when PatAtom::Kind::IntLiteral
          io << 'i' << pat.value.as(Int32) << ';'
        when PatAtom::Kind::StringLiteral
          s = pat.value.as(String)
          io << 's' << s.bytesize << ':' << s << ';'
        when PatAtom::Kind::BoolLiteral
          io << (pat.value.as(Bool) ? "B;" : "b;")
        when PatAtom::Kind::IntFormal
          io << "x;"
        when PatAtom::Kind::StringFormal
          io << "z;"
        when PatAtom::Kind::BoolFormal
          io << "y;"
        when PatAtom::Kind::Wild
          io << "w;"
        end
      end

      private def read_to(data : String, i : Int32, delimiter : Char) : {String, Int32}
        j = i
        while j < data.bytesize && data.byte_at(j).chr != delimiter
          j += 1
        end
        {data[i...j], j + 1}
      end

      private def decode_val(data : String, i : Int32) : {ValAtom, Int32}
        case data.byte_at(i).chr
        when 'i'
          s, j = read_to(data, i + 1, ';')
          {ValAtom.int(s.to_i), j}
        when 'B'
          {ValAtom.bool(true), i + 2}
        when 'b'
          {ValAtom.bool(false), i + 2}
        when 's'
          len_s, j = read_to(data, i + 1, ':')
          len = len_s.to_i
          value = data[j, len]
          {ValAtom.string(value), j + len + 1}
        else
          raise "decode_val: invalid atom"
        end
      end

      private def decode_pat(data : String, i : Int32) : {PatAtom, Int32}
        case data.byte_at(i).chr
        when 'i'
          s, j = read_to(data, i + 1, ';')
          {PatAtom.int_literal(s.to_i), j}
        when 'B'
          {PatAtom.bool_literal(true), i + 2}
        when 'b'
          {PatAtom.bool_literal(false), i + 2}
        when 's'
          len_s, j = read_to(data, i + 1, ':')
          len = len_s.to_i
          value = data[j, len]
          {PatAtom.string_literal(value), j + len + 1}
        when 'x'
          {PatAtom.int_formal, i + 2}
        when 'y'
          {PatAtom.bool_formal, i + 2}
        when 'z'
          {PatAtom.string_formal, i + 2}
        when 'w'
          {PatAtom.wild, i + 2}
        else
          raise "decode_pat: invalid atom"
        end
      end
    end

    module NetMessage
      enum Kind : UInt16
        OutTuple = 0
        InReq    = 1
        RdReq    = 2
        Accept   = 3
        Cancel   = 4
        InReply  = 5
      end

      struct OutTuple
        getter tuple : TupleValue

        def initialize(@tuple : TupleValue)
        end
      end

      struct InReq
        getter trans_id : Int32
        getter pat : Template

        def initialize(@trans_id : Int32, @pat : Template)
        end
      end

      struct RdReq
        getter trans_id : Int32
        getter pat : Template

        def initialize(@trans_id : Int32, @pat : Template)
        end
      end

      struct Accept
        getter trans_id : Int32

        def initialize(@trans_id : Int32)
        end
      end

      struct Cancel
        getter trans_id : Int32

        def initialize(@trans_id : Int32)
        end
      end

      struct InReply
        getter trans_id : Int32
        getter vals : Array(ValAtom)

        def initialize(@trans_id : Int32, @vals : Array(ValAtom))
        end
      end

      alias Message = OutTuple | InReq | RdReq | Accept | Cancel | InReply

      def self.encode(msg : Message) : Bytes
        kind, body = case msg
                     when OutTuple
                       {Kind::OutTuple, DataRep.encode_tuple(msg.tuple)}
                     when InReq
                       {Kind::InReq, encode_with_id(msg.trans_id, DataRep.encode_template(msg.pat))}
                     when RdReq
                       {Kind::RdReq, encode_with_id(msg.trans_id, DataRep.encode_template(msg.pat))}
                     when Accept
                       {Kind::Accept, encode_id_only(msg.trans_id)}
                     when Cancel
                       {Kind::Cancel, encode_id_only(msg.trans_id)}
                     when InReply
                       {Kind::InReply, encode_with_id(msg.trans_id, DataRep.encode_values(msg.vals))}
                     else
                       raise "unsupported message variant"
                     end

        io = IO::Memory.new
        io.write_bytes(kind.value, IO::ByteFormat::BigEndian)
        io.write_bytes(body.bytesize.to_u16, IO::ByteFormat::BigEndian)
        io << body
        io.to_slice
      end

      def self.decode(data : Bytes) : Message
        io = IO::Memory.new(data)
        kind = Kind.from_value(io.read_bytes(UInt16, IO::ByteFormat::BigEndian))
        len = io.read_bytes(UInt16, IO::ByteFormat::BigEndian).to_i
        body = io.gets_to_end[0, len]

        case kind
        when Kind::OutTuple
          OutTuple.new(DataRep.decode_tuple(body))
        when Kind::InReq
          id, payload = decode_id_and_payload(body)
          InReq.new(id, DataRep.decode_template(payload))
        when Kind::RdReq
          id, payload = decode_id_and_payload(body)
          RdReq.new(id, DataRep.decode_template(payload))
        when Kind::Accept
          Accept.new(decode_id_only(body))
        when Kind::Cancel
          Cancel.new(decode_id_only(body))
        when Kind::InReply
          id, payload = decode_id_and_payload(body)
          InReply.new(id, DataRep.decode_values(payload))
        else
          raise "invalid message kind"
        end
      end

      private def self.encode_id_only(id : Int32) : String
        io = IO::Memory.new
        io.write_bytes(id.to_i32, IO::ByteFormat::BigEndian)
        io.to_s
      end

      private def self.encode_with_id(id : Int32, payload : String) : String
        encode_id_only(id) + payload
      end

      private def self.decode_id_only(body : String) : Int32
        IO::Memory.new(body).read_bytes(Int32, IO::ByteFormat::BigEndian)
      end

      private def self.decode_id_and_payload(body : String) : {Int32, String}
        io = IO::Memory.new(body)
        id = io.read_bytes(Int32, IO::ByteFormat::BigEndian)
        {id, io.gets_to_end}
      end
    end

    alias TsId = Int32
    alias RequestId = {TsId, Int32}

    struct Reply
      getter trans_id : Int32
      getter vals : Array(ValAtom)

      def initialize(@trans_id : Int32, @vals : Array(ValAtom))
      end
    end

    struct ClientOut
      getter tuple : TupleValue

      def initialize(@tuple : TupleValue)
      end
    end

    struct ClientInReq
      getter from : TsId
      getter trans_id : Int32
      getter remove : Bool
      getter pat : Template
      getter reply : Proc(Reply, Nil)

      def initialize(@from : TsId, @trans_id : Int32, @remove : Bool, @pat : Template, @reply : Proc(Reply, Nil))
      end
    end

    struct ClientAccept
      getter from : TsId
      getter trans_id : Int32

      def initialize(@from : TsId, @trans_id : Int32)
      end
    end

    struct ClientCancel
      getter from : TsId
      getter trans_id : Int32

      def initialize(@from : TsId, @trans_id : Int32)
      end
    end

    alias ClientReq = ClientOut | ClientInReq | ClientAccept | ClientCancel

    private enum QueryStatus
      Waiting
      Held
    end

    private class WaitMatch
      getter id : RequestId
      getter reply : Proc(Reply, Nil)
      getter template : Template

      def initialize(@id : RequestId, @reply : Proc(Reply, Nil), @template : Template)
      end
    end

    private class BindingsMatch
      getter id : RequestId
      getter reply : Proc(Reply, Nil)
      getter bindings : Array(ValAtom)

      def initialize(@id : RequestId, @reply : Proc(Reply, Nil), @bindings : Array(ValAtom))
      end
    end

    private class Bucket
      getter key : ValAtom
      property waiting : Array(WaitMatch)
      property holds : Array({RequestId, TupleValue})
      property items : Array(TupleValue)

      def initialize(@key : ValAtom)
        @waiting = [] of WaitMatch
        @holds = [] of {RequestId, TupleValue}
        @items = [] of TupleValue
      end

      def empty? : Bool
        waiting.empty? && holds.empty? && items.empty?
      end
    end

    private class TupleStore
      @tuples = Hash(ValAtom, Bucket).new
      @queries = Hash(RequestId, {QueryStatus, Bucket}).new

      def add(tuple : TupleValue) : BindingsMatch?
        key = tuple.tag
        bucket = @tuples[key]?
        unless bucket
          b = Bucket.new(key)
          b.items << tuple
          @tuples[key] = b
          return
        end

        idx = bucket.waiting.index do |w|
          !!match(w.template, tuple)
        end

        if idx
          wait = bucket.waiting.delete_at(idx)
          bindings = match(wait.template, tuple)
          raise "tuple store invariant violated for waiting match" unless bindings
          bucket.holds << {wait.id, tuple}
          @queries[wait.id] = {QueryStatus::Held, bucket}
          BindingsMatch.new(wait.id, wait.reply, bindings)
        else
          bucket.items << tuple
          nil
        end
      end

      def input(wait : WaitMatch) : Array(ValAtom)?
        key = wait.template.tag
        bucket = @tuples[key]?
        unless bucket
          b = Bucket.new(key)
          b.waiting << wait
          @tuples[key] = b
          @queries[wait.id] = {QueryStatus::Waiting, b}
          return
        end

        idx = bucket.items.index { |item| !!match(wait.template, item) }
        if idx
          item = bucket.items.delete_at(idx)
          bindings = match(wait.template, item)
          raise "tuple store invariant violated for input match" unless bindings
          bucket.holds << {wait.id, item}
          @queries[wait.id] = {QueryStatus::Held, bucket}
          bindings
        else
          bucket.waiting << wait
          @queries[wait.id] = {QueryStatus::Waiting, bucket}
          nil
        end
      end

      def cancel(id : RequestId) : BindingsMatch?
        entry = @queries.delete(id)
        return unless entry

        status, bucket = entry
        case status
        when QueryStatus::Waiting
          if idx = bucket.waiting.index { |w| w.id == id }
            bucket.waiting.delete_at(idx)
          end
          cleanup_bucket(bucket)
          nil
        when QueryStatus::Held
          return unless idx = bucket.holds.index { |(hold_id, _)| hold_id == id }
          tuple = bucket.holds.delete_at(idx)[1]
          add(tuple)
        end
      end

      def remove(id : RequestId) : Nil
        entry = @queries.delete(id)
        return unless entry

        status, bucket = entry
        if status.held?
          if idx = bucket.holds.index { |(hold_id, _)| hold_id == id }
            bucket.holds.delete_at(idx)
          end
        else
          if idx = bucket.waiting.index { |w| w.id == id }
            bucket.waiting.delete_at(idx)
          end
        end
        cleanup_bucket(bucket)
      end

      private def cleanup_bucket(bucket : Bucket)
        @tuples.delete(bucket.key) if bucket.empty?
      end

      private def match(template : Template, tuple : TupleValue) : Array(ValAtom)?
        return unless template.fields.size == tuple.fields.size

        bindings = [] of ValAtom
        template.fields.each_with_index do |pat, idx|
          value = tuple.fields[idx]
          case pat.kind
          when PatAtom::Kind::IntLiteral
            return unless value.kind.int? && value.value == pat.value
          when PatAtom::Kind::StringLiteral
            return unless value.kind.string? && value.value == pat.value
          when PatAtom::Kind::BoolLiteral
            return unless value.kind.bool? && value.value == pat.value
          when PatAtom::Kind::IntFormal
            return unless value.kind.int?
            bindings << value
          when PatAtom::Kind::StringFormal
            return unless value.kind.string?
            bindings << value
          when PatAtom::Kind::BoolFormal
            return unless value.kind.bool?
            bindings << value
          when PatAtom::Kind::Wild
            # Wildcard matches without binding.
          end
        end
        bindings
      end
    end

    private struct InMsg
      getter tid : Int64
      getter remove : Bool
      getter pat : Template
      getter repl_fn : Proc(Array(ValAtom), TsId, Nil)

      def initialize(@tid : Int64, @remove : Bool, @pat : Template, @repl_fn : Proc(Array(ValAtom), TsId, Nil))
      end
    end

    private struct CancelMsg
      getter tid : Int64

      def initialize(@tid : Int64)
      end
    end

    private struct AcceptMsg
      getter tid : Int64
      getter ts_id : TsId

      def initialize(@tid : Int64, @ts_id : TsId)
      end
    end

    private alias ProxyMsg = InMsg | CancelMsg | AcceptMsg

    private struct TransInfo
      getter id : Int32
      getter remove : Bool
      getter repl_fn : Proc(Array(ValAtom), TsId, Nil)

      def initialize(@id : Int32, @remove : Bool, @repl_fn : Proc(Array(ValAtom), TsId, Nil))
      end
    end

    private class OutputServer
      private struct Out
        getter tuple : TupleValue

        def initialize(@tuple : TupleValue)
        end
      end

      private struct Add
        getter id : Int32
        getter target : Proc(TupleValue, Nil)

        def initialize(@id : Int32, @target : Proc(TupleValue, Nil))
        end
      end

      private struct Remove
        getter id : Int32

        def initialize(@id : Int32)
        end
      end

      private alias Msg = Out | Add | Remove

      @mb : CML::Mailbox(Msg)
      @mb = CML::Mailbox(Msg).new

      def initialize(local_target : Proc(TupleValue, Nil))
        CML.spawn do
          targets = [{0_i32, local_target}] of {Int32, Proc(TupleValue, Nil)}
          idx = 0
          loop do
            case msg = @mb.recv
            when Out
              next if targets.empty?
              _, target = targets[idx % targets.size]
              target.call(msg.tuple)
              idx = (idx + 1) % targets.size
            when Add
              if existing_idx = targets.index { |(id, _)| id == msg.id }
                targets[existing_idx] = {msg.id, msg.target}
              else
                targets << {msg.id, msg.target}
              end
              idx = 0 if idx >= targets.size
            when Remove
              targets.reject! { |(id, _)| id == msg.id }
              idx = 0 if idx >= targets.size
            end
          end
        end
      end

      def output(tuple : TupleValue)
        @mb.send(Out.new(tuple))
      end

      def add_target(id : Int32, target : Proc(TupleValue, Nil))
        @mb.send(Add.new(id, target))
      end

      def remove_target(id : Int32)
        @mb.send(Remove.new(id))
      end
    end

    private class ServerConn
      getter ts_id : TsId
      @out_mb : CML::Mailbox(NetMessage::Message)
      @reply_mb : CML::Mailbox(Reply)

      def initialize(@ts_id : TsId, @out_mb : CML::Mailbox(NetMessage::Message), @reply_mb : CML::Mailbox(Reply))
      end

      def send_out_tuple(tuple : TupleValue)
        @out_mb.send(NetMessage::OutTuple.new(tuple))
      end

      def send_in_req(trans_id : Int32, remove : Bool, pat : Template)
        if remove
          @out_mb.send(NetMessage::InReq.new(trans_id, pat))
        else
          @out_mb.send(NetMessage::RdReq.new(trans_id, pat))
        end
      end

      def send_accept(trans_id : Int32)
        @out_mb.send(NetMessage::Accept.new(trans_id))
      end

      def send_cancel(trans_id : Int32)
        @out_mb.send(NetMessage::Cancel.new(trans_id))
      end

      def reply_evt : Event(Reply)
        @reply_mb.recv_evt
      end
    end

    class TupleSpace
      @request : Proc(ProxyMsg, Nil)
      @output : Proc(TupleValue, Nil)

      @@tid_counter = Atomic(Int64).new(0_i64)

      private def initialize(@request : Proc(ProxyMsg, Nil), @output : Proc(TupleValue, Nil))
      end

      private def self.parse_host(host_str : String) : {String, Int32}
        if host_str.empty?
          raise ArgumentError.new("bad hostname format")
        elsif host_str.starts_with?('[')
          close_idx = host_str.index(']')
          raise ArgumentError.new("bad hostname format") unless close_idx

          host = host_str.byte_slice(1, close_idx - 1)
          suffix = host_str.byte_slice(close_idx + 1)
          return {host, 7001} if suffix.empty?

          unless suffix.starts_with?(':') && suffix.bytesize > 1
            raise ArgumentError.new("bad hostname format")
          end

          {host, suffix.byte_slice(1).to_i}
        elsif host_str.count(':') > 1
          # Bare IPv6 literal without an explicit port.
          {host_str, 7001}
        elsif colon_idx = host_str.rindex(':')
          host = host_str.byte_slice(0, colon_idx)
          port = host_str.byte_slice(colon_idx + 1)
          raise ArgumentError.new("bad hostname format") if host.empty? || port.empty?
          {host, port.to_i}
        else
          {host_str, 7001}
        end
      end

      private def self.start_tuple_server(ts_mb : CML::Mailbox(ClientReq))
        CML.spawn do
          store = TupleStore.new
          loop do
            case req = ts_mb.recv
            when ClientOut
              if m = store.add(req.tuple)
                m.reply.call(Reply.new(m.id[1], m.bindings))
              end
            when ClientInReq
              wait = WaitMatch.new({req.from, req.trans_id}, req.reply, req.pat)
              if bindings = store.input(wait)
                req.reply.call(Reply.new(req.trans_id, bindings))
              end
            when ClientAccept
              store.remove({req.from, req.trans_id})
            when ClientCancel
              if m = store.cancel({req.from, req.trans_id})
                m.reply.call(Reply.new(m.id[1], m.bindings))
              end
            end
          end
        end
      end

      private def self.spawn_buffers(ts_id : TsId, socket : TCPSocket, ts_mb : CML::Mailbox(ClientReq), on_disconnect : Proc(Nil)? = nil) : ServerConn
        out_mb = CML::Mailbox(NetMessage::Message).new
        reply_mb = CML::Mailbox(Reply).new
        disconnected = CML::AtomicFlag.new
        reader_socket = socket
        writer_socket = begin
          writer_fd = CSocket.dup(reader_socket.fd)
          raise IO::Error.from_errno("dup failed") if writer_fd < 0

          TCPSocket.from_handle(
            writer_fd,
            family: reader_socket.family,
            type: reader_socket.type,
            protocol: reader_socket.protocol
          )
        end

        close_once = -> {
          if disconnected.compare_and_set(false, true)
            reader_socket.close rescue nil
            writer_socket.close rescue nil
            on_disconnect.try(&.call)
          end
        }

        CML.spawn do
          begin
            loop do
              msg = out_mb.recv
              data = NetMessage.encode(msg)
              frame = IO::Memory.new
              frame.write_bytes(data.size.to_u32, IO::ByteFormat::BigEndian)
              frame.write(data)

              bytes = frame.to_slice
              off = 0
              while off < bytes.size
                written = CML.sync(CML::Socket.send_evt(writer_socket, bytes[off...bytes.size]))
                raise IO::Error.new("socket send returned non-positive byte count") if written <= 0
                off += written
              end
            end
          rescue
            close_once.call
          end
        end

        CML.spawn do
          begin
            read_exact = ->(bytes : Int32) do
              out = Bytes.new(bytes)
              off = 0
              while off < bytes
                chunk = CML.sync(CML::Socket.recv_evt(reader_socket, bytes - off))
                raise IO::EOFError.new if chunk.empty?
                out[off, chunk.size].copy_from(chunk)
                off += chunk.size
              end
              out
            end

            loop do
              header = read_exact.call(4)
              size = IO::ByteFormat::BigEndian.decode(UInt32, header).to_i
              data = read_exact.call(size)
              msg = NetMessage.decode(data)

              case msg
              when NetMessage::OutTuple
                ts_mb.send(ClientOut.new(msg.tuple))
              when NetMessage::InReq
                ts_mb.send(ClientInReq.new(ts_id, msg.trans_id, true, msg.pat, ->(reply : Reply) {
                  out_mb.send(NetMessage::InReply.new(reply.trans_id, reply.vals))
                }))
              when NetMessage::RdReq
                ts_mb.send(ClientInReq.new(ts_id, msg.trans_id, false, msg.pat, ->(reply : Reply) {
                  out_mb.send(NetMessage::InReply.new(reply.trans_id, reply.vals))
                }))
              when NetMessage::Accept
                ts_mb.send(ClientAccept.new(ts_id, msg.trans_id))
              when NetMessage::Cancel
                ts_mb.send(ClientCancel.new(ts_id, msg.trans_id))
              when NetMessage::InReply
                reply_mb.send(Reply.new(msg.trans_id, msg.vals))
              end
            end
          rescue
            close_once.call
          end
        end

        ServerConn.new(ts_id, out_mb, reply_mb)
      end

      private def self.build_proxy(
        ts_id : TsId,
        req_mb : CML::Mailbox(ProxyMsg),
        reply_evt_fn : Proc(Event(Reply)),
        send_in_req : Proc(Int32, Bool, Template, Nil),
        send_accept : Proc(Int32, Nil),
        send_cancel : Proc(Int32, Nil),
        init_in_reqs : Array(InMsg) = [] of InMsg,
      ) : Proc(ProxyMsg, Nil)
        CML.spawn do
          by_tid = Hash(Int64, TransInfo).new
          by_trans_id = Hash(Int32, TransInfo).new
          next_trans = Atomic(Int32).new(0_i32)

          handle_req = ->(msg : ProxyMsg) do
            case msg
            when InMsg
              id = next_trans.add(1)
              info = TransInfo.new(id, msg.remove, msg.repl_fn)
              by_tid[msg.tid] = info
              by_trans_id[id] = info
              send_in_req.call(id, msg.remove, msg.pat)
            when CancelMsg
              if info = by_tid.delete(msg.tid)
                by_trans_id.delete(info.id)
                send_cancel.call(info.id)
              end
            when AcceptMsg
              if info = by_tid.delete(msg.tid)
                by_trans_id.delete(info.id)
                if msg.ts_id == ts_id && info.remove
                  send_accept.call(info.id)
                else
                  send_cancel.call(info.id)
                end
              end
            end
          end

          init_in_reqs.each { |msg| handle_req.call(msg) }

          loop do
            CML.select(
              CML.wrap(req_mb.recv_evt) do |msg|
                handle_req.call(msg)
              end,
              CML.wrap(reply_evt_fn.call) do |reply|
                if info = by_trans_id[reply.trans_id]?
                  info.repl_fn.call(reply.vals, ts_id)
                end
              end
            )
          end
        end

        ->(msg : ProxyMsg) { req_mb.send(msg) }
      end

      def self.join_tuple_space(local_port : Int32? = nil, remote_hosts : Array(String) = [] of String) : self
        ts_mb = CML::Mailbox(ClientReq).new
        start_tuple_server(ts_mb)

        if local_port.nil? && remote_hosts.empty?
          local_proxy_req_mb = CML::Mailbox(ProxyMsg).new
          local_proxy_reply_mb = CML::Mailbox(Reply).new
          local_proxy = build_proxy(
            0,
            local_proxy_req_mb,
            -> : Event(Reply) { local_proxy_reply_mb.recv_evt },
            ->(trans_id : Int32, remove : Bool, pat : Template) {
              ts_mb.send(ClientInReq.new(0, trans_id, remove, pat, ->(reply : Reply) {
                local_proxy_reply_mb.send(reply)
              }))
            },
            ->(trans_id : Int32) { ts_mb.send(ClientAccept.new(0, trans_id)) },
            ->(trans_id : Int32) { ts_mb.send(ClientCancel.new(0, trans_id)) }
          )

          request = ->(msg : ProxyMsg) { local_proxy.call(msg) }
          output = ->(tuple : TupleValue) { ts_mb.send(ClientOut.new(tuple)) }
          return new(request, output)
        end

        proxy_targets = Hash(Int32, Proc(ProxyMsg, Nil)).new
        in_log = Hash(Int64, InMsg).new
        state_mtx = CML::Sync::Mutex.new
        # Keep 0 reserved for the always-present local target.
        next_remote_target_id = Atomic(Int32).new(1_i32)

        request = ->(msg : ProxyMsg) {
          targets = state_mtx.synchronize do
            case msg
            when InMsg
              in_log[msg.tid] = msg
            when CancelMsg, AcceptMsg
              in_log.delete(msg.tid)
            end
            proxy_targets.values.dup
          end
          targets.each(&.call(msg))
        }

        output_server = OutputServer.new(->(tuple : TupleValue) { ts_mb.send(ClientOut.new(tuple)) })

        local_proxy_req_mb = CML::Mailbox(ProxyMsg).new
        local_proxy_reply_mb = CML::Mailbox(Reply).new
        local_proxy = build_proxy(
          0,
          local_proxy_req_mb,
          -> : Event(Reply) { local_proxy_reply_mb.recv_evt },
          ->(trans_id : Int32, remove : Bool, pat : Template) {
            ts_mb.send(ClientInReq.new(0, trans_id, remove, pat, ->(reply : Reply) {
              local_proxy_reply_mb.send(reply)
            }))
          },
          ->(trans_id : Int32) { ts_mb.send(ClientAccept.new(0, trans_id)) },
          ->(trans_id : Int32) { ts_mb.send(ClientCancel.new(0, trans_id)) }
        )
        state_mtx.synchronize { proxy_targets[0] = local_proxy }

        add_remote_conn = ->(conn : ServerConn, target_id : Int32) {
          remote_req_mb = CML::Mailbox(ProxyMsg).new
          state_mtx.synchronize do
            init_in_reqs = in_log.values
            remote_proxy = build_proxy(
              conn.ts_id,
              remote_req_mb,
              -> : Event(Reply) { conn.reply_evt },
              ->(trans_id : Int32, remove : Bool, pat : Template) { conn.send_in_req(trans_id, remove, pat) },
              ->(trans_id : Int32) { conn.send_accept(trans_id) },
              ->(trans_id : Int32) { conn.send_cancel(trans_id) },
              init_in_reqs
            )
            proxy_targets[target_id] = remote_proxy
          end
          output_server.add_target(target_id, ->(tuple : TupleValue) { conn.send_out_tuple(tuple) })
        }

        if local_port || !remote_hosts.empty?
          listen_port = local_port || 7001
          accepted_counter = Atomic(Int32).new(remote_hosts.size + 1)
          server = TCPServer.new("0.0.0.0", listen_port)

          CML.spawn do
            loop do
              begin
                socket = server.accept
                ts_id = accepted_counter.add(1)
                target_id = next_remote_target_id.add(1)
                conn = spawn_buffers(ts_id, socket, ts_mb, -> {
                  state_mtx.synchronize { proxy_targets.delete(target_id) }
                  output_server.remove_target(target_id)
                })
                add_remote_conn.call(conn, target_id)
              rescue ex : IO::Error
                # Keep server loop alive on transient accept/decode errors.
              end
            end
          end

          remote_hosts.each_with_index do |host_str, idx|
            host, port = parse_host(host_str)
            socket = nil
            last_error : Exception? = nil

            300.times do
              begin
                socket = TCPSocket.new(host, port)
                break
              rescue ex
                last_error = ex
                sleep 100.milliseconds
              end
            end

            unless socket
              message = last_error ? last_error.not_nil!.message : "timed out"
              raise ::Socket::Error.new("failed to connect to remote tuple space #{host}:#{port}: #{message}")
            end

            target_id = next_remote_target_id.add(1)
            conn = spawn_buffers((idx + 1).to_i32, socket, ts_mb, -> {
              state_mtx.synchronize { proxy_targets.delete(target_id) }
              output_server.remove_target(target_id)
            })
            add_remote_conn.call(conn, target_id)
          end
        end

        output = ->(tuple : TupleValue) { output_server.output(tuple) }

        new(request, output)
      end

      def out(tuple : TupleValue)
        @output.call(tuple)
      end

      def in_evt(template : Template) : Event(Array(ValAtom))
        do_input_op(template, remove: true)
      end

      def rd_evt(template : Template) : Event(Array(ValAtom))
        do_input_op(template, remove: false)
      end

      private def do_input_op(template : Template, remove : Bool) : Event(Array(ValAtom))
        CML.with_nack do |nack|
          reply_ch = CML.channel(Array(ValAtom))

          CML.spawn do
            tid = @@tid_counter.add(1)
            repl_mb = CML::Mailbox({Array(ValAtom), TsId}).new
            handle_nack = -> { @request.call(CancelMsg.new(tid)) }

            @request.call(InMsg.new(tid, remove, template, ->(vals : Array(ValAtom), ts_id : TsId) {
              repl_mb.send({vals, ts_id})
            }))

            CML.select(
              CML.wrap(nack) { handle_nack.call },
              CML.wrap(repl_mb.recv_evt) do |tuple|
                vals, ts_id = tuple
                CML.select(
                  CML.wrap(nack) { handle_nack.call },
                  CML.wrap(reply_ch.send_evt(vals)) do
                    if remove
                      @request.call(AcceptMsg.new(tid, ts_id))
                    else
                      @request.call(CancelMsg.new(tid))
                    end
                  end
                )
              end
            )
          end

          reply_ch.recv_evt
        end
      end
    end

    module Helpers
      def self.ival(value : Int32) : ValAtom
        ValAtom.int(value)
      end

      def self.sval(value : String) : ValAtom
        ValAtom.string(value)
      end

      def self.bval(value : Bool) : ValAtom
        ValAtom.bool(value)
      end

      def self.ipat(value : Int32) : PatAtom
        PatAtom.int_literal(value)
      end

      def self.spat(value : String) : PatAtom
        PatAtom.string_literal(value)
      end

      def self.bpat(value : Bool) : PatAtom
        PatAtom.bool_literal(value)
      end

      def self.iform : PatAtom
        PatAtom.int_formal
      end

      def self.sform : PatAtom
        PatAtom.string_formal
      end

      def self.bform : PatAtom
        PatAtom.bool_formal
      end

      def self.wild : PatAtom
        PatAtom.wild
      end
    end
  end
end

module CML
  # Chapter 9 Linda compatibility namespace backed by TupleLib.
  module Linda
    alias ValAtom = CML::TupleLib::ValAtom
    alias PatAtom = CML::TupleLib::PatAtom

    struct TupleRep(T)
      getter tag : ValAtom
      getter fields : Array(T)

      def initialize(@tag : ValAtom, @fields : Array(T))
      end

      def to_tuple_lib : CML::TupleLib::TupleRep(T)
        CML::TupleLib::TupleRep(T).new(@tag, @fields)
      end
    end

    alias Tuple = TupleRep(ValAtom)
    alias Template = TupleRep(PatAtom)

    class TupleSpace
      @inner : CML::TupleLib::TupleSpace

      def initialize(local_port : Int32? = nil, remote_hosts : Array(String) = [] of String)
        @inner = CML::TupleLib::TupleSpace.join_tuple_space(local_port: local_port, remote_hosts: remote_hosts)
      end

      def self.join_tuple_space(local_port : Int32? = nil, remote_hosts : Array(String) = [] of String) : self
        new(local_port: local_port, remote_hosts: remote_hosts)
      end

      def out(tuple : Tuple)
        @inner.out(tuple.to_tuple_lib)
      end

      def in_evt(template : Template) : Event(Array(ValAtom))
        @inner.in_evt(template.to_tuple_lib)
      end

      def rd_evt(template : Template) : Event(Array(ValAtom))
        @inner.rd_evt(template.to_tuple_lib)
      end
    end

    module Helpers
      def self.ival(value : Int32) : ValAtom
        CML::TupleLib::Helpers.ival(value)
      end

      def self.sval(value : String) : ValAtom
        CML::TupleLib::Helpers.sval(value)
      end

      def self.bval(value : Bool) : ValAtom
        CML::TupleLib::Helpers.bval(value)
      end

      def self.ipat(value : Int32) : PatAtom
        CML::TupleLib::Helpers.ipat(value)
      end

      def self.spat(value : String) : PatAtom
        CML::TupleLib::Helpers.spat(value)
      end

      def self.bpat(value : Bool) : PatAtom
        CML::TupleLib::Helpers.bpat(value)
      end

      def self.iform : PatAtom
        CML::TupleLib::Helpers.iform
      end

      def self.sform : PatAtom
        CML::TupleLib::Helpers.sform
      end

      def self.bform : PatAtom
        CML::TupleLib::Helpers.bform
      end

      def self.wild : PatAtom
        CML::TupleLib::Helpers.wild
      end
    end

    def self.ival(value : Int32) : ValAtom
      Helpers.ival(value)
    end

    def self.sval(value : String) : ValAtom
      Helpers.sval(value)
    end

    def self.bval(value : Bool) : ValAtom
      Helpers.bval(value)
    end

    def self.ipat(value : Int32) : PatAtom
      Helpers.ipat(value)
    end

    def self.spat(value : String) : PatAtom
      Helpers.spat(value)
    end

    def self.bpat(value : Bool) : PatAtom
      Helpers.bpat(value)
    end

    def self.iform : PatAtom
      Helpers.iform
    end

    def self.sform : PatAtom
      Helpers.sform
    end

    def self.bform : PatAtom
      Helpers.bform
    end

    def self.wild : PatAtom
      Helpers.wild
    end

    def self.join_tuple_space(local_port : Int32? = nil, remote_hosts : Array(String) = [] of String) : TupleSpace
      TupleSpace.join_tuple_space(local_port: local_port, remote_hosts: remote_hosts)
    end
  end
end
