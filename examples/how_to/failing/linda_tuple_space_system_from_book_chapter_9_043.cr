# linda_tuple_space_system_from_book_chapter_9_043.cr
# Extracted from: how_to.md
# Section: linda_tuple_space_system_from_book_chapter_9
# Lines: 1583-1988
#
# ----------------------------------------------------------

require "../../src/cml/linda"

require "../../src/cml"
require "../../src/cml/multicast"

module CML
  module Linda
    # Value atoms (integers, strings, booleans)
    struct ValAtom
      enum Kind
        Int; String; Bool
      end

      getter kind : Kind
      getter value : Int32 | String | Bool

      def initialize(@kind, @value); end

      def self.int(i : Int32) = new(Kind::Int, i)
      def self.string(s : String) = new(Kind::String, s)
      def self.bool(b : Bool) = new(Kind::Bool, b)
    end

    # Pattern atoms (literals, formals, wildcards)
    struct PatAtom
      enum Kind
        IntLiteral; StringLiteral; BoolLiteral
        IntFormal; StringFormal; BoolFormal
        Wild
      end

      getter kind : Kind
      getter value : Int32 | String | Bool | Nil

      def initialize(@kind, @value = nil); end

      def self.int_literal(i : Int32) = new(Kind::IntLiteral, i)
      def self.string_literal(s : String) = new(Kind::StringLiteral, s)
      def self.bool_literal(b : Bool) = new(Kind::BoolLiteral, b)
      def self.int_formal = new(Kind::IntFormal)
      def self.string_formal = new(Kind::StringFormal)
      def self.bool_formal = new(Kind::BoolFormal)
      def self.wild = new(Kind::Wild)
    end

    # Tuple representation
    struct TupleRep(T)
      getter tag : ValAtom
      getter fields : Array(T)

      def initialize(@tag, @fields); end
    end

    alias Tuple = TupleRep(ValAtom)
    alias Template = TupleRep(PatAtom)

    # Server requests
    abstract struct Request
    end

    struct OutRequest < Request
      getter tuple : Tuple
      def initialize(@tuple); end
    end

    struct InRequest < Request
      getter template : Template
      getter reply : CML::Chan(Array(ValAtom))
      getter destructive : Bool
      getter id : Int64

      def initialize(@template, @reply, @destructive, @id); end
    end

    struct CancelRequest < Request
      getter id : Int64
      def initialize(@id); end
    end

    # Distributed Tuple Space
    class DistributedTupleSpace
      @req_mch : CML::Multicast::Chan(Request)  # Multicast to all proxies
      @output_ch : CML::Chan(Tuple)             # Output to distribution server
      @next_id = Atomic(Int64).new(0)

      def initialize(server_count : Int32)
        # Create multicast channel for broadcasting input requests
        @req_mch = CML.mchannel(Request)

        # Create output channel
        @output_ch = CML::Chan(Tuple).new

        # Create tuple servers and proxies
        create_servers_and_proxies(server_count)

        # Create output distribution server
        create_output_server(server_count)
      end

      private def create_servers_and_proxies(count : Int32)
        count.times do |server_id|
          # Each server has its own storage
          server = TupleServer.new(server_id)

          # Create proxy for this server
          proxy_port = @req_mch.port
          proxy = ServerProxy.new(server_id, server, proxy_port)

          # Start proxy thread
          CML.spawn { proxy.run }
        end
      end

      private def create_output_server(server_count : Int32)
        CML.spawn do
          servers = Array(TupleServer).new(server_count)
          current = 0

          loop do
            tuple = CML.sync(@output_ch.recv_evt)

            # Round-robin distribution (simplified policy)
            server = servers[current]
            server.out(tuple)

            current = (current + 1) % server_count
          end
        end
      end

      def out(tuple : Tuple)
        CML.sync(@output_ch.send_evt(tuple))
      end

      def in_evt(template : Template) : CML::Event(Array(ValAtom))
        CML.with_nack do |nack|
          reply = CML.channel(Array(ValAtom))
          waiter_id = @next_id.add(1)

          # Broadcast request to all proxies
          @req_mch.multicast(
            InRequest.new(template, reply, true, waiter_id)
          )

          # Cancel if operation is aborted
          CML.spawn do
            CML.sync(nack)
            @req_mch.multicast(CancelRequest.new(waiter_id))
          end

          reply.recv_evt
        end
      end

      def rd_evt(template : Template) : CML::Event(Array(ValAtom))
        CML.with_nack do |nack|
          reply = CML.channel(Array(ValAtom))
          waiter_id = @next_id.add(1)

          # Broadcast request (non-destructive)
          @req_mch.multicast(
            InRequest.new(template, reply, false, waiter_id)
          )

          # Cancel if aborted
          CML.spawn do
            CML.sync(nack)
            @req_mch.multicast(CancelRequest.new(waiter_id))
          end

          reply.recv_evt
        end
      end
    end

    # Tuple Server (manages local storage)
    class TupleServer
      @id : Int32
      @tuples = [] of Tuple
      @waiters = Hash(Int64, InRequest).new

      def initialize(@id); end

      def out(tuple : Tuple)
        # Check if any waiter matches
        matched_id = nil
        @waiters.each do |id, waiter|
          if matches?(waiter.template, tuple)
            matched_id = id
            # Send reply to waiter
            bindings = extract_bindings(waiter.template, tuple)
            CML.sync(waiter.reply.send_evt(bindings))

            # Remove tuple if destructive
            unless waiter.destructive
              @tuples << tuple
            end

            break
          end
        end

        if matched_id
          @waiters.delete(matched_id)
        else
          @tuples << tuple
        end
      end

      def in_request(req : InRequest)
        # Try to match with existing tuples
        matched_index = @tuples.index do |tuple|
          matches?(req.template, tuple)
        end

        if matched_index
          tuple = @tuples[matched_index]
          bindings = extract_bindings(req.template, tuple)

          # Remove if destructive
          @tuples.delete_at(matched_index) if req.destructive

          # Send reply
          CML.sync(req.reply.send_evt(bindings))
        else
          # Remember waiter
          @waiters[req.id] = req
        end
      end

      def cancel_request(id : Int64)
        @waiters.delete(id)
      end

      private def matches?(template : Template, tuple : Tuple) : Bool
        return false unless template.tag == tuple.tag
        return false unless template.fields.size == tuple.fields.size

        template.fields.each_with_index do |pat, i|
          val = tuple.fields[i]

          case pat.kind
          when PatAtom::Kind::IntLiteral
            return false unless val.kind == ValAtom::Kind::Int && val.value == pat.value
          when PatAtom::Kind::StringLiteral
            return false unless val.kind == ValAtom::Kind::String && val.value == pat.value
          when PatAtom::Kind::BoolLiteral
            return false unless val.kind == ValAtom::Kind::Bool && val.value == pat.value
          when PatAtom::Kind::IntFormal
            return false unless val.kind == ValAtom::Kind::Int
          when PatAtom::Kind::StringFormal
            return false unless val.kind == ValAtom::Kind::String
          when PatAtom::Kind::BoolFormal
            return false unless val.kind == ValAtom::Kind::Bool
          when PatAtom::Kind::Wild
            # Matches anything
          end
        end

        true
      end

      private def extract_bindings(template : Template, tuple : Tuple) : Array(ValAtom)
        bindings = [] of ValAtom

        template.fields.each_with_index do |pat, i|
          val = tuple.fields[i]

          case pat.kind
          when PatAtom::Kind::IntFormal,
               PatAtom::Kind::StringFormal,
               PatAtom::Kind::BoolFormal,
               PatAtom::Kind::Wild
            bindings << val
          else
            # Literals don't produce bindings
          end
        end

        bindings
      end
    end

    # Server Proxy (mediates between clients and servers)
    class ServerProxy
      @server_id : Int32
      @server : TupleServer
      @request_port : CML::Multicast::Port(Request)
      @request_ch : CML::Chan(Request)

      def initialize(@server_id, @server, request_port)
        @request_port = request_port
        @request_ch = CML::Chan(Request).new
      end

      def run
        # Forward multicast requests to server
        CML.spawn do
          loop do
            req = CML.sync(@request_port.recv_evt)
            handle_request(req)
          end
        end

        # Also handle direct requests (for output)
        loop do
          req = CML.sync(@request_ch.recv_evt)
          handle_request(req)
        end
      end

      private def handle_request(req : Request)
        case req
        when OutRequest
          @server.out(req.tuple)
        when InRequest
          @server.in_request(req)
        when CancelRequest
          @server.cancel_request(req.id)
        end
      end
    end
  end
end

# Example: Dining Philosophers with Linda
def dining_philosophers(n : Int32)
  space = CML::Linda::DistributedTupleSpace.new(1)  # Single server for demo

  # Helper functions for creating tuples
  def chopstick_tuple(pos : Int32)
    tag = CML::Linda::ValAtom.string("chopstick")
    fields = [CML::Linda::ValAtom.int(pos)]
    CML::Linda::TupleRep.new(tag, fields)
  end

  def ticket_tuple
    tag = CML::Linda::ValAtom.string("ticket")
    fields = [] of CML::Linda::ValAtom
    CML::Linda::TupleRep.new(tag, fields)
  end

  # Initialize tuple space with chopsticks and tickets
  n.times do |i|
    space.out(chopstick_tuple(i))
  end

  (n - 1).times do
    space.out(ticket_tuple)
  end

  # Philosopher thread
  philosopher = ->(id : Int32) {
    loop do
      puts "Philosopher #{id} thinking..."
      sleep rand(0.1..0.5)

      puts "Philosopher #{id} hungry..."

      # Need ticket and two chopsticks
      ticket_template = CML::Linda::Template.new(
        CML::Linda::ValAtom.string("ticket"),
        [] of CML::Linda::PatAtom
      )

      left_chop = CML::Linda::Template.new(
        CML::Linda::ValAtom.string("chopstick"),
        [CML::Linda::PatAtom.int_literal(id)]
      )

      right_chop = CML::Linda::Template.new(
        CML::Linda::ValAtom.string("chopstick"),
        [CML::Linda::PatAtom.int_literal((id + 1) % n)]
      )

      # Get ticket (blocks until available)
      CML.sync(space.in_evt(ticket_template))

      # Get chopsticks
      CML.sync(space.in_evt(left_chop))
      CML.sync(space.in_evt(right_chop))

      puts "Philosopher #{id} eating..."
      sleep rand(0.1..0.3)

      # Return resources
      space.out(chopstick_tuple(id))
      space.out(chopstick_tuple((id + 1) % n))
      space.out(ticket_tuple)

      puts "Philosopher #{id} finished eating"
    end
  }

  # Start philosophers
  n.times do |i|
    CML.spawn { philosopher.call(i) }
  end

  # Run for a while
  sleep 5.0
  puts "Dinner is over!"
end

# Run the example
dining_philosophers(5)