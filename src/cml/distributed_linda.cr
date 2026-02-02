# Distributed Linda Implementation - Chapter 9 of "Concurrent Programming in ML"
# Extends the existing CML::Linda module with distributed tuple space support.
# This implementation follows the architecture from the book:
# 1. Network Layer: TCP/IP communication and message serialization
# 2. Server Layer: Tuple storage, proxies, and distribution
# 3. Client Layer: Public API (joinTupleSpace, out, inEvt, rdEvt)

require "json"
require "socket"
require "../cml"
require "./linda/linda"
require "./mailbox"
require "./multicast"
require "./simple_rpc"

module CML
  module DistributedLinda
    class TupleStore; end

    # Re-export types from CML::Linda for convenience
    alias ValAtom = Linda::ValAtom
    alias PatAtom = Linda::PatAtom
    alias Tuple = Linda::Tuple
    alias Template = Linda::Template
    alias TupleRep = Linda::TupleRep

    # Import helper functions
    module Helpers
      include Linda::Helpers
    end

    # ===========================================================================
    # DataRep: Serialization/deserialization for network transmission
    # ===========================================================================
    # In the SML/NJ implementation, this uses packed binary encoding.
    # For simplicity, we use JSON serialization in this Crystal port.

    module DataRep
      extend self

      # Serialize a ValAtom to JSON
      private def encode_val_atom(atom : ValAtom) : JSON::Any
        case atom.kind
        when ValAtom::Kind::Int
          {"kind" => "int", "value" => atom.value.as(Int32)}.to_json
        when ValAtom::Kind::String
          {"kind" => "string", "value" => atom.value.as(String)}.to_json
        when ValAtom::Kind::Bool
          {"kind" => "bool", "value" => atom.value.as(Bool)}.to_json
        else
          raise "Unknown ValAtom kind: #{atom.kind}"
        end
      end

      # Serialize a PatAtom to JSON
      private def encode_pat_atom(atom : PatAtom) : JSON::Any
        case atom.kind
        when PatAtom::Kind::IntLiteral
          {"kind" => "int_literal", "value" => atom.value.as(Int32)}.to_json
        when PatAtom::Kind::StringLiteral
          {"kind" => "string_literal", "value" => atom.value.as(String)}.to_json
        when PatAtom::Kind::BoolLiteral
          {"kind" => "bool_literal", "value" => atom.value.as(Bool)}.to_json
        when PatAtom::Kind::IntFormal
          {"kind" => "int_formal"}.to_json
        when PatAtom::Kind::StringFormal
          {"kind" => "string_formal"}.to_json
        when PatAtom::Kind::BoolFormal
          {"kind" => "bool_formal"}.to_json
        when PatAtom::Kind::Wild
          {"kind" => "wild"}.to_json
        else
          raise "Unknown PatAtom kind: #{atom.kind}"
        end
      end

      # Deserialize a ValAtom from JSON
      private def decode_val_atom(json : JSON::Any) : ValAtom
        kind_str = json["kind"].as_s
        case kind_str
        when "int"
          ValAtom.int(json["value"].as_i)
        when "string"
          ValAtom.string(json["value"].as_s)
        when "bool"
          ValAtom.bool(json["value"].as_bool)
        else
          raise "Unknown ValAtom kind in JSON: #{kind_str}"
        end
      end

      # Deserialize a PatAtom from JSON
      private def decode_pat_atom(json : JSON::Any) : PatAtom
        kind_str = json["kind"].as_s
        case kind_str
        when "int_literal"
          PatAtom.int_literal(json["value"].as_i)
        when "string_literal"
          PatAtom.string_literal(json["value"].as_s)
        when "bool_literal"
          PatAtom.bool_literal(json["value"].as_bool)
        when "int_formal"
          PatAtom.int_formal
        when "string_formal"
          PatAtom.string_formal
        when "bool_formal"
          PatAtom.bool_formal
        when "wild"
          PatAtom.wild
        else
          raise "Unknown PatAtom kind in JSON: #{kind_str}"
        end
      end

      # Calculate size of serialized tuple (for compatibility with SML API)
      def tuple_sz(tuple : Tuple) : Int32
        # Return approximate size in bytes
        json = encode_tuple(tuple)
        json.to_s.bytesize
      end

      # Calculate size of serialized template
      def template_sz(template : Template) : Int32
        json = encode_template(template)
        json.to_s.bytesize
      end

      # Calculate size of serialized value list
      def values_sz(values : Array(ValAtom)) : Int32
        json = encode_values(values)
        json.to_s.bytesize
      end

      # Encode tuple to JSON string
      def encode_tuple(tuple : Tuple) : String
        {
          "tag"    => encode_val_atom(tuple.tag),
          "fields" => tuple.fields.map { |atom| encode_val_atom(atom) },
        }.to_json
      end

      # Encode template to JSON string
      def encode_template(template : Template) : String
        {
          "tag"    => encode_val_atom(template.tag),
          "fields" => template.fields.map { |atom| encode_pat_atom(atom) },
        }.to_json
      end

      # Encode value list to JSON string
      def encode_values(values : Array(ValAtom)) : String
        values.map { |atom| encode_val_atom(atom) }.to_json
      end

      # Decode tuple from JSON string
      def decode_tuple(json_str : String) : Tuple
        json = JSON.parse(json_str)
        tag = decode_val_atom(json["tag"])
        fields = json["fields"].as_a.map { |field_json| decode_val_atom(field_json) }
        TupleRep(ValAtom).new(tag, fields)
      end

      # Decode template from JSON string
      def decode_template(json_str : String) : Template
        json = JSON.parse(json_str)
        tag = decode_val_atom(json["tag"])
        fields = json["fields"].as_a.map { |field_json| decode_pat_atom(field_json) }
        TupleRep(PatAtom).new(tag, fields)
      end

      # Decode value list from JSON string
      def decode_values(json_str : String) : Array(ValAtom)
        json = JSON.parse(json_str)
        json.as_a.map { |atom_json| decode_val_atom(atom_json) }
      end

      # Alternative API matching SML signature: encode to buffer at offset
      def encode_tuple(tuple : Tuple, buffer : Bytes, offset : Int32) : Int32
        json_str = encode_tuple(tuple)
        bytes = json_str.to_slice
        buffer[offset, bytes.size] = bytes
        bytes.size
      end

      def encode_template(template : Template, buffer : Bytes, offset : Int32) : Int32
        json_str = encode_template(template)
        bytes = json_str.to_slice
        buffer[offset, bytes.size] = bytes
        bytes.size
      end

      def encode_values(values : Array(ValAtom), buffer : Bytes, offset : Int32) : Int32
        json_str = encode_values(values)
        bytes = json_str.to_slice
        buffer[offset, bytes.size] = bytes
        bytes.size
      end

      # Decode from buffer at offset
      def decode_tuple(buffer : Bytes, offset : Int32) : {Tuple, Int32}
        # Find null terminator or end of buffer for JSON string
        end_idx = offset
        while end_idx < buffer.size && buffer[end_idx] != 0
          end_idx += 1
        end
        json_str = String.new(buffer[offset...end_idx])
        tuple = decode_tuple(json_str)
        {tuple, end_idx - offset}
      end

      def decode_template(buffer : Bytes, offset : Int32) : {Template, Int32}
        end_idx = offset
        while end_idx < buffer.size && buffer[end_idx] != 0
          end_idx += 1
        end
        json_str = String.new(buffer[offset...end_idx])
        template = decode_template(json_str)
        {template, end_idx - offset}
      end

      def decode_values(buffer : Bytes, offset : Int32) : {Array(ValAtom), Int32}
        end_idx = offset
        while end_idx < buffer.size && buffer[end_idx] != 0
          end_idx += 1
        end
        json_str = String.new(buffer[offset...end_idx])
        values = decode_values(json_str)
        {values, end_idx - offset}
      end
    end

    # ===========================================================================
    # NetMessage: Network message types and serialization
    # ===========================================================================
    # Matches the SML datatype from Listing 9.5

    module NetMessage
      enum Kind : UInt8
        OutTuple = 0
        InReq    = 1
        RdReq    = 2
        Accept   = 3
        Cancel   = 4
        InReply  = 5
      end

      # Network message types
      alias Message = OutTuple | InReq | RdReq | Accept | Cancel | InReply

      struct OutTuple
        getter tuple : Tuple

        def initialize(@tuple : Tuple)
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

      # Serialize message to bytes for network transmission
      def self.serialize(msg : Message) : Bytes
        io = IO::Memory.new
        writer = IO::ByteWriter.new(io)

        case msg
        when OutTuple
          writer.write_byte(Kind::OutTuple.value)
          json_str = DataRep.encode_tuple(msg.tuple)
          writer.write_bytes(json_str.bytesize.to_u32, IO::ByteFormat::NetworkEndian)
          io.write(json_str.to_slice)
        when InReq
          writer.write_byte(Kind::InReq.value)
          writer.write_bytes(msg.trans_id.to_u32, IO::ByteFormat::NetworkEndian)
          json_str = DataRep.encode_template(msg.pat)
          writer.write_bytes(json_str.bytesize.to_u32, IO::ByteFormat::NetworkEndian)
          io.write(json_str.to_slice)
        when RdReq
          writer.write_byte(Kind::RdReq.value)
          writer.write_bytes(msg.trans_id.to_u32, IO::ByteFormat::NetworkEndian)
          json_str = DataRep.encode_template(msg.pat)
          writer.write_bytes(json_str.bytesize.to_u32, IO::ByteFormat::NetworkEndian)
          io.write(json_str.to_slice)
        when Accept
          writer.write_byte(Kind::Accept.value)
          writer.write_bytes(msg.trans_id.to_u32, IO::ByteFormat::NetworkEndian)
        when Cancel
          writer.write_byte(Kind::Cancel.value)
          writer.write_bytes(msg.trans_id.to_u32, IO::ByteFormat::NetworkEndian)
        when InReply
          writer.write_byte(Kind::InReply.value)
          writer.write_bytes(msg.trans_id.to_u32, IO::ByteFormat::NetworkEndian)
          json_str = DataRep.encode_values(msg.vals)
          writer.write_bytes(json_str.bytesize.to_u32, IO::ByteFormat::NetworkEndian)
          io.write(json_str.to_slice)
        end

        io.to_slice
      end

      # Deserialize message from bytes
      def self.deserialize(data : Bytes) : Message
        io = IO::Memory.new(data)
        reader = IO::ByteReader.new(io)

        kind_val = reader.read_byte
        kind = Kind.from_value?(kind_val) || raise "Invalid message kind: #{kind_val}"

        case kind
        when Kind::OutTuple
          len = reader.read_bytes(UInt32, IO::ByteFormat::NetworkEndian).to_i
          json_bytes = Bytes.new(len)
          io.read_fully(json_bytes)
          json_str = String.new(json_bytes)
          tuple = DataRep.decode_tuple(json_str)
          OutTuple.new(tuple)
        when Kind::InReq
          trans_id = reader.read_bytes(UInt32, IO::ByteFormat::NetworkEndian).to_i
          len = reader.read_bytes(UInt32, IO::ByteFormat::NetworkEndian).to_i
          json_bytes = Bytes.new(len)
          io.read_fully(json_bytes)
          json_str = String.new(json_bytes)
          pat = DataRep.decode_template(json_str)
          InReq.new(trans_id, pat)
        when Kind::RdReq
          trans_id = reader.read_bytes(UInt32, IO::ByteFormat::NetworkEndian).to_i
          len = reader.read_bytes(UInt32, IO::ByteFormat::NetworkEndian).to_i
          json_bytes = Bytes.new(len)
          io.read_fully(json_bytes)
          json_str = String.new(json_bytes)
          pat = DataRep.decode_template(json_str)
          RdReq.new(trans_id, pat)
        when Kind::Accept
          trans_id = reader.read_bytes(UInt32, IO::ByteFormat::NetworkEndian).to_i
          Accept.new(trans_id)
        when Kind::Cancel
          trans_id = reader.read_bytes(UInt32, IO::ByteFormat::NetworkEndian).to_i
          Cancel.new(trans_id)
        when Kind::InReply
          trans_id = reader.read_bytes(UInt32, IO::ByteFormat::NetworkEndian).to_i
          len = reader.read_bytes(UInt32, IO::ByteFormat::NetworkEndian).to_i
          json_bytes = Bytes.new(len)
          io.read_fully(json_bytes)
          json_str = String.new(json_bytes)
          vals = DataRep.decode_values(json_str)
          InReply.new(trans_id, vals)
        end
      end
    end

    # ===========================================================================
    # Network Layer: TCP/IP communication and connection management
    # ===========================================================================
    # Implements the NETWORK signature from Listing 9.6

    class NetworkError < Exception
    end

    # Network module implementing the NETWORK signature
    module Network
      extend self

      # Type aliases matching SML signature
      alias TsId = Int32
      alias Reply = NetMessage::InReply

      # Client request types (Listing 9.6)
      alias ClientReq = OutTuple | InReq | Accept | Cancel

      struct OutTuple
        getter tuple : Tuple

        def initialize(@tuple : Tuple)
        end
      end

      struct InReq
        getter from : TsId
        getter trans_id : Int32
        getter remove : Bool
        getter pat : Template
        getter reply : Proc(Reply, Nil)

        def initialize(@from : TsId, @trans_id : Int32, @remove : Bool, @pat : Template, @reply : Proc(Reply, Nil))
        end
      end

      struct Accept
        getter from : TsId
        getter trans_id : Int32

        def initialize(@from : TsId, @trans_id : Int32)
        end
      end

      struct Cancel
        getter from : TsId
        getter trans_id : Int32

        def initialize(@from : TsId, @trans_id : Int32)
        end
      end

      # Remote server information
      struct RemoteServerInfo
        getter name : String
        getter id : TsId
        getter conn : ServerConn

        def initialize(@name : String, @id : TsId, @conn : ServerConn)
        end
      end

      # Server connection abstraction (Listing 9.8)
      class ServerConn
        @out_mb : Mailbox(NetMessage::Message)
        @in_mb : Mailbox(Reply)

        def initialize(@out_mb : Mailbox(NetMessage::Message), @in_mb : Mailbox(Reply))
        end

        # Send a message through this connection
        def send(msg : NetMessage::Message)
          @out_mb.send(msg)
        end

        # Get reply event for this connection
        def reply_evt : Event(Reply)
          @in_mb.recv_evt
        end

        # Helper methods matching SML API
        def send_out_tuple(tuple : Tuple)
          send(NetMessage::OutTuple.new(tuple))
        end

        def send_in_req(trans_id : Int32, remove : Bool, pat : Template)
          send(NetMessage::InReq.new(trans_id, pat))
        end

        def send_accept(trans_id : Int32)
          send(NetMessage::Accept.new(trans_id))
        end

        def send_cancel(trans_id : Int32)
          send(NetMessage::Cancel.new(trans_id))
        end
      end

      # Network handle
      class NetworkHandle
        @shutdown_flag = AtomicFlag.new

        def initialize
        end

        def shutdown
          @shutdown_flag.set(true)
        end

        def shutdown?
          @shutdown_flag.get
        end
      end

      # Parse host string in format "host:port" or just "host"
      private def parse_host(host_str : String) : {String, Int32}
        if host_str.includes?(':')
          parts = host_str.split(':')
          host = parts[0]
          port = parts[1].to_i
          {host, port}
        else
          {host_str, 7001} # Default Linda port
        end
      rescue
        raise NetworkError.new("Invalid host format: #{host_str}")
      end

      # Create socket buffers for a connection (Listing 9.8)
      private def spawn_buffers(id : TsId, socket : TCPSocket, ts_mb : Mailbox(ClientReq)) : ServerConn
        out_mb = Mailbox(NetMessage::Message).new
        in_mb = Mailbox(Reply).new

        # Output loop: send messages from mailbox to socket
        spawn do
          begin
            loop do
              msg = out_mb.recv
              data = NetMessage.serialize(msg)
              socket.write_bytes(data.size.to_u32, IO::ByteFormat::NetworkEndian)
              socket.write(data)
            end
          rescue ex : Exception
            # Socket closed or error
            socket.close
          end
        end

        # Input loop: receive messages from socket and forward to appropriate mailbox
        spawn do
          begin
            loop do
              # Read message size
              size_bytes = Bytes.new(4)
              socket.read_fully(size_bytes)
              size = IO::ByteReader.new(IO::Memory.new(size_bytes)).read_bytes(UInt32, IO::ByteFormat::NetworkEndian).to_i

              # Read message data
              data = Bytes.new(size)
              socket.read_fully(data)

              msg = NetMessage.deserialize(data)

              case msg
              when NetMessage::OutTuple
                ts_mb.send(OutTuple.new(msg.tuple))
              when NetMessage::InReq
                ts_mb.send(InReq.new(id, msg.trans_id, true, msg.pat, ->(reply : Reply) {
                  in_mb.send(reply)
                }))
              when NetMessage::RdReq
                ts_mb.send(InReq.new(id, msg.trans_id, false, msg.pat, ->(reply : Reply) {
                  in_mb.send(reply)
                }))
              when NetMessage::Accept
                ts_mb.send(Accept.new(id, msg.trans_id))
              when NetMessage::Cancel
                ts_mb.send(Cancel.new(id, msg.trans_id))
              when NetMessage::InReply
                in_mb.send(msg)
              end
            end
          rescue ex : Exception
            # Socket closed or error
            socket.close
          end
        end

        ServerConn.new(out_mb, in_mb)
      end

      # Spawn network server (Listing 9.7)
      private def spawn_net_server(my_port : Int32?, start_id : TsId, ts_mb : Mailbox(ClientReq), add_ts : Proc(RemoteServerInfo, Nil)) : NetworkHandle
        handle = NetworkHandle.new

        spawn do
          server = TCPServer.new(my_port || 7001)
          next_id = start_id

          begin
            loop do
              break if handle.shutdown?

              # Accept with timeout to allow shutdown checking
              client = server.accept?
              if client
                conn = spawn_buffers(next_id, client, ts_mb)
                # In real implementation, we'd get hostname from socket
                info = RemoteServerInfo.new("host-#{next_id}", next_id, conn)
                add_ts.call(info)
                next_id += 1
              else
                # No connection, sleep a bit to avoid busy loop
                sleep 0.1
              end
            end
          ensure
            server.close
          end
        end

        handle
      end

      # Initialize network (Listing 9.7)
      def init_network(port : Int32?, remote_hosts : Array(String), ts_req_mb : Mailbox(ClientReq), add_ts : Proc(RemoteServerInfo, Nil)) : {TsId, NetworkHandle, Array(RemoteServerInfo)}
        # Parse remote hosts
        hosts = remote_hosts.map { |h| parse_host(h) }

        # My ID is always 0 (local tuple space)
        my_id = 0

        # Start network server
        start_id = hosts.size + 1
        network = spawn_net_server(port, start_id, ts_req_mb, add_ts)

        # Connect to remote hosts
        servers = [] of RemoteServerInfo

        hosts.each_with_index do |(host, port), idx|
          server_id = idx + 1

          spawn do
            begin
              socket = TCPSocket.new(host, port)
              conn = spawn_buffers(server_id, socket, ts_req_mb)
              info = RemoteServerInfo.new(host, server_id, conn)
              servers << info
              add_ts.call(info)
            rescue ex : Exception
              # Connection failed, will retry?
              # In production, we'd have reconnection logic
            end
          end
        end

        {my_id, network, servers}
      end

      # Convenience method matching SML signature
      def init_network(args : NamedTuple(
                         port: Int32?,
                         remote: Array(String),
                         ts_req_mb: Mailbox(ClientReq),
                         add_ts: Proc(RemoteServerInfo, Nil))) : NamedTuple(my_id: TsId, network: NetworkHandle, servers: Array(RemoteServerInfo))
        my_id, network, servers = init_network(args[:port], args[:remote], args[:ts_req_mb], args[:add_ts])
        {my_id: my_id, network: network, servers: servers}
      end
    end

    # ===========================================================================
    # TupleStore: Distributed tuple storage with matching
    # ===========================================================================
    # Implements the TUPLE_STORE signature from Listing 9.13

    # Re-open ValAtom to add hash support for hash table keys
    struct CML::Linda::ValAtom
      def hash
        kind.hash ^ value.hash
      end
    end

    # Type aliases matching SML signature
    alias Id = {Network::TsId, Int32} # (ts_id * int)
    alias Bindings = Array(ValAtom)

    # Match record as in Listing 9.13
    class Match(T)
      getter id : Id
      getter reply : Proc(Network::Reply, Nil)
      getter ext : T

      def initialize(@id : Id, @reply : Proc(Network::Reply, Nil), @ext : T)
      end
    end

    # Query status for tracking held vs waiting matches
    enum QueryStatus
      Held
      Waiting
    end

    # Bucket representation (Listing 9.14)
    class Bucket
      getter key : ValAtom
      property waiting : Array(Match(Template))
      property holds : Array({Id, Tuple})
      property items : Array(Tuple)

      def initialize(@key : ValAtom)
        @waiting = [] of Match(Template)
        @holds = [] of {Id, Tuple}
        @items = [] of Tuple
      end

      def empty? : Bool
        @waiting.empty? && @holds.empty? && @items.empty?
      end
    end

    # TupleStore implementation
    class TupleStore
      @tuples : Hash(ValAtom, Bucket)
      @queries : Hash(Id, {QueryStatus, Bucket})

      def initialize
        @tuples = Hash(ValAtom, Bucket).new
        @queries = Hash(Id, {QueryStatus, Bucket}).new
      end

      # Create new empty tuple store
      def self.new_store : TupleStore
        new
      end

      # Match function (Listing 9.15)
      private def match(template : Template, tuple : Tuple) : Bindings?
        return unless template.tag == tuple.tag
        return unless template.fields.size == tuple.fields.size

        bindings = [] of ValAtom

        template.fields.each_with_index do |pat, idx|
          val = tuple.fields[idx]
          case pat.kind
          when PatAtom::Kind::IntLiteral
            return unless val.kind == ValAtom::Kind::Int && val.value == pat.value
          when PatAtom::Kind::StringLiteral
            return unless val.kind == ValAtom::Kind::String && val.value == pat.value
          when PatAtom::Kind::BoolLiteral
            return unless val.kind == ValAtom::Kind::Bool && val.value == pat.value
          when PatAtom::Kind::IntFormal
            return unless val.kind == ValAtom::Kind::Int
            bindings << val
          when PatAtom::Kind::StringFormal
            return unless val.kind == ValAtom::Kind::String
            bindings << val
          when PatAtom::Kind::BoolFormal
            return unless val.kind == ValAtom::Kind::Bool
            bindings << val
          when PatAtom::Kind::Wild
            bindings << val
          end
        end

        bindings
      end

      # Helper: remove first element from list matching predicate
      private def remove_from_list(list : Array(T), &predicate : T -> Bool) : {T?, Array(T)}
        result = nil
        new_list = [] of T
        list.each do |item|
          if result.nil? && predicate.call(item)
            result = item
          else
            new_list << item
          end
        end
        {result, new_list}
      end

      # Add a tuple to the store (Listing 9.16)
      def add(tuple : Tuple) : Match(Bindings)?
        key = tuple.tag
        bucket = @tuples[key]?

        if bucket.nil?
          # Create new bucket with this tuple as only item
          bucket = Bucket.new(key)
          bucket.items << tuple
          @tuples[key] = bucket
          nil
        else
          # Scan waiting list for a match
          new_waiting = [] of Match(Template)
          matched = nil

          bucket.waiting.each do |wait_match|
            if matched
              # Keep remaining waiting matches
              new_waiting << wait_match
              next
            end

            bindings = match(wait_match.ext, tuple)
            if bindings
              # Found a match!
              matched = Match(Bindings).new(wait_match.id, wait_match.reply, bindings)
              # Move tuple to holds for this transaction
              bucket.holds << {wait_match.id, tuple}
              @queries[wait_match.id] = {QueryStatus::Held, bucket}
            else
              new_waiting << wait_match
            end
          end

          bucket.waiting = new_waiting

          if matched
            matched
          else
            # No match, add tuple to items
            bucket.items << tuple
            nil
          end
        end
      end

      # Input operation (Listing 9.17)
      def input(match : Match(Template)) : Bindings?
        key = match.ext.tag
        bucket = @tuples[key]?

        if bucket.nil?
          # Create new bucket with this waiting request
          bucket = Bucket.new(key)
          bucket.waiting << match
          @tuples[key] = bucket
          @queries[match.id] = {QueryStatus::Waiting, bucket}
          nil
        else
          # Scan items for a match
          new_items = [] of Tuple
          matched_bindings = nil

          bucket.items.each do |tuple|
            if matched_bindings
              # Keep remaining items
              new_items << tuple
              next
            end

            bindings = match(match.ext, tuple)
            if bindings
              matched_bindings = bindings
              # Move tuple to holds
              bucket.holds << {match.id, tuple}
              @queries[match.id] = {QueryStatus::Held, bucket}
            else
              new_items << tuple
            end
          end

          bucket.items = new_items

          if matched_bindings
            # If bucket becomes empty, remove it
            if bucket.empty?
              @tuples.delete(key)
            end
            matched_bindings
          else
            # No match, add to waiting list
            bucket.waiting << match
            @queries[match.id] = {QueryStatus::Waiting, bucket}
            nil
          end
        end
      end

      # Cancel operation (Listing 9.18)
      def cancel(id : Id) : Match(Bindings)?
        status_bucket = @queries.delete(id)
        return unless status_bucket

        status, bucket = status_bucket

        case status
        when QueryStatus::Waiting
          # Remove from waiting list
          _, new_waiting = remove_from_list(bucket.waiting) do |m|
            m.id == id
          end
          bucket.waiting = new_waiting

          # If bucket becomes empty, remove it
          if bucket.empty?
            @tuples.delete(bucket.key)
          end

          nil
        when QueryStatus::Held
          # Remove from holds and add tuple back to items
          removed_hold, new_holds = remove_from_list(bucket.holds) do |(hold_id, _)|
            hold_id == id
          end

          return unless removed_hold

          bucket.holds = new_holds
          tuple = removed_hold.last
          # Re-add tuple to store (may match another waiting request)
          add(tuple)
        end
      end

      # Remove operation (Listing 9.18)
      def remove(id : Id) : Nil
        status_bucket = @queries.delete(id)
        return unless status_bucket

        status, bucket = status_bucket

        if status == QueryStatus::Held
          # Remove from holds
          _, new_holds = remove_from_list(bucket.holds) do |(hold_id, _)|
            hold_id == id
          end
          bucket.holds = new_holds

          # If bucket becomes empty, remove it
          if bucket.empty?
            @tuples.delete(bucket.key)
          end
        end
      end
    end

    # ===========================================================================
    # mkTupleServer: Create a tuple server and local proxy (Listing 9.20)
    # ===========================================================================

    # Connection operations record returned by mkTupleServer
    class ConnOps
      getter out_op : Proc(Tuple, Nil)
      getter in_evt : Proc(Template, Event(Array(ValAtom)))
      getter rd_evt : Proc(Template, Event(Array(ValAtom)))
      getter add_ts : Proc(Network::ServerConn, Nil)

      def initialize(@out_op, @in_evt, @rd_evt, @add_ts)
      end
    end

    # Create a tuple server and its local proxy
    def self.mk_tuple_server : ConnOps
      # Create mailbox for tuple server requests
      ts_mb = Mailbox(Network::ClientReq).new

      # Spawn tuple server
      TupleServer.new(ts_mb)

      # Create local proxy server
      # proxy_server returns {out, inEvt, rdEvt, addTS}
      # We'll implement proxy_server separately
      # For now, create a placeholder
      proxy = proxy_server(ts_mb, 0) # ts_id = 0 for local server

      ConnOps.new(
        ->(tuple : Tuple) { proxy[:out_op].call(tuple) },
        ->(template : Template) { proxy[:in_evt].call(template) },
        ->(template : Template) { proxy[:rd_evt].call(template) },
        ->(conn : Network::ServerConn) { proxy[:add_ts].call(conn) }
      )
    end

    # ===========================================================================
    # proxyServer: Proxy server for remote and local tuple servers (Listing 9.11)
    # ===========================================================================

    # Proxy server return type
    alias ProxyOps = NamedTuple(
      out_op: Proc(Tuple, Nil),
      in_evt: Proc(Template, Event(Array(ValAtom))),
      rd_evt: Proc(Template, Event(Array(ValAtom))),
      add_ts: Proc(Network::ServerConn, Nil))

    # Create a proxy server for a tuple server
    private def proxy_server(ts_mb : Mailbox(Network::ClientReq), ts_id : Network::TsId) : ProxyOps
      # Transaction ID counter
      trans_counter = Atomic(Int32).new(0)

      # Map from (ts_id, trans_id) to reply channel
      pending_transactions = Hash({Network::TsId, Int32}, Chan(Array(ValAtom))).new
      pending_mutex = CML::Sync::Mutex.new

      # Mailbox for messages from tuple server connections
      proxy_mb = Mailbox(NamedTuple(
        ts_id: Network::TsId,
        msg: Network::ClientReq | Network::Reply)).new

      # Spawn proxy server thread
      spawn do
        loop do
          item = proxy_mb.recv
          msg = item[:msg]

          case msg
          when Network::OutTuple
            # Forward to tuple server
            ts_mb.send(msg)
          when Network::InReq
            # Forward to tuple server
            ts_mb.send(msg)
          when Network::Accept
            # Forward to tuple server
            ts_mb.send(msg)
          when Network::Cancel
            # Forward to tuple server
            ts_mb.send(msg)
          when Network::Reply
            # Look up transaction and send reply
            trans_id = msg.trans_id
            key = {item[:ts_id], trans_id}
            pending_mutex.synchronize do
              if chan = pending_transactions.delete(key)
                chan.send(msg.vals)
              end
            end
          end
        end
      end

      # Helper to generate unique transaction ID
      gen_trans_id = -> { trans_counter.add(1) }

      # out function: send tuple to tuple server
      out_fn = ->(tuple : Tuple) {
        ts_mb.send(Network::OutTuple.new(tuple))
      }

      # Helper to create input/read events
      make_wait_event = ->(template : Template, remove : Bool) {
        CML.with_nack do |nack|
          trans_id = gen_trans_id.call
          reply_chan = CML.channel(Array(ValAtom))

          # Register transaction
          pending_mutex.synchronize do
            pending_transactions[{ts_id, trans_id}] = reply_chan
          end

          # Send request to tuple server
          ts_mb.send(Network::InReq.new(ts_id, trans_id, remove, template, ->(_reply : Network::Reply) {
            # This reply callback is called by network layer when reply arrives
            # It will be forwarded to proxy_mb and then to reply_chan
          }))

          # Cancel on nack
          CML.spawn do
            CML.sync(nack)
            ts_mb.send(Network::Cancel.new(ts_id, trans_id))
            pending_mutex.synchronize do
              pending_transactions.delete({ts_id, trans_id})
            end
          end

          reply_chan.recv_evt
        end
      }

      in_evt_fn = ->(template : Template) {
        make_wait_event.call(template, true)
      }

      rd_evt_fn = ->(template : Template) {
        make_wait_event.call(template, false)
      }

      # addTS function: add a new tuple server connection
      add_ts_fn = ->(conn : Network::ServerConn) {
        # Spawn a fiber to forward messages from this connection to proxy_mb
        spawn do
          loop do
            # Wait for reply event from connection
            reply = CML.sync(conn.reply_evt)
            proxy_mb.send({ts_id: conn.object_id, msg: reply})
          end
        end
        # Also forward OutTuple messages from proxy to this connection?
        # Actually, out_fn sends to ts_mb (local tuple server).
        # For remote servers, we need to route out tuples via output server.
        # The add_ts function in Listing 9.11 adds the connection to the proxy's
        # internal table so that replies can be routed.
        # We'll handle this differently in the OutputServer.
      }

      {
        out_op: out_fn,
        in_evt: in_evt_fn,
        rd_evt: rd_evt_fn,
        add_ts: add_ts_fn,
      }
    end

    # ===========================================================================
    # OutputServer: Distribute tuples to tuple servers (Listing 9.22)
    # ===========================================================================

    class OutputServer
      @conns : Array(Network::ServerConn)
      @next_idx : Atomic(Int32)

      def initialize
        @conns = [] of Network::ServerConn
        @next_idx = Atomic(Int32).new(0)
      end

      # Add a tuple server connection
      def add_ts(conn : Network::ServerConn)
        @conns << conn
      end

      # Output tuple to round-robin selected server
      def output(tuple : Tuple)
        if @conns.empty?
          raise "No tuple servers available"
        end

        idx = @next_idx.add(1) % @conns.size
        conn = @conns[idx]
        conn.send_out_tuple(tuple)
      end

      # Get output event for tuple (non-blocking)
      def out_evt(tuple : Tuple) : Event(Nil)
        CML.guard -> {
          output(tuple)
          nil
        }
      end
    end

    # ===========================================================================
    # Client Layer API: Distributed tuple space operations
    # ===========================================================================

    # Join a distributed tuple space
    def self.join_tuple_space(local_port : Int32? = nil, remote_hosts : Array(String) = [] of String) : Linda::TupleSpace
      # Create mailbox for tuple server requests
      ts_req_mb = Mailbox(Network::ClientReq).new

      # Server list accumulator
      servers = [] of Network::RemoteServerInfo
      add_ts = ->(info : Network::RemoteServerInfo) { servers << info }

      # Initialize network
      _, _, remote_servers = Network.init_network(
        port: local_port,
        remote_hosts: remote_hosts,
        ts_req_mb: ts_req_mb,
        add_ts: add_ts
      )

      # Create local tuple server and proxy
      conn_ops = mk_tuple_server

      # Add remote servers to local proxy
      remote_servers.each do |server|
        conn_ops.add_ts.call(server.conn)
      end

      # Create output server for distributing tuples
      output_server = OutputServer.new

      # Add all tuple server connections to output server
      servers.each do |server|
        output_server.add_ts(server.conn)
      end

      # Return a TupleSpace that uses the distributed infrastructure
      DistributedTupleSpace.new(conn_ops, output_server)
    end

    # Distributed tuple space implementation
    class DistributedTupleSpace < Linda::TupleSpace
      @conn_ops : ConnOps
      @output_server : OutputServer

      def initialize(@conn_ops, @output_server)
        # Don't call super - we're replacing the local implementation
        @req_chan = nil
      end

      def out(tuple : Tuple)
        # Use round-robin output server
        @output_server.output(tuple)
      end

      def in_evt(template : Template) : Event(Array(ValAtom))
        @conn_ops.in_evt.call(template)
      end

      def rd_evt(template : Template) : Event(Array(ValAtom))
        @conn_ops.rd_evt.call(template)
      end
    end
  end
end
