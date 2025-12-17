module CML
  # Port of the CML-Linda interface from "Concurrent Programming in ML" (Section 9.1).
  # This is a faithful CML-style implementation using channels and events (no mutexes).
  module Linda
    # -----------------------
    # Value/Pattern Atoms (mirror SML datatypes IVval/SVval/BVval and IPat/SPat/etc.)
    # -----------------------

    # Immutable tagged value used in tuples.
    struct ValAtom
      enum Kind
        Int
        String
        Bool
      end

      getter kind : Kind
      getter value : Int32 | String | Bool

      def initialize(@kind, @value : Int32 | String | Bool)
      end

      def self.int(i : Int32) : self
        new(Kind::Int, i)
      end

      def self.string(s : String) : self
        new(Kind::String, s)
      end

      def self.bool(b : Bool) : self
        new(Kind::Bool, b)
      end

      def ==(other : ValAtom)
        kind == other.kind && value == other.value
      end
    end

    # Template atoms: literals, formals, or wildcard.
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

      def initialize(@kind, @value : Int32 | String | Bool | Nil = nil)
      end

      def self.int_literal(i : Int32) : self
        new(Kind::IntLiteral, i)
      end

      def self.string_literal(s : String) : self
        new(Kind::StringLiteral, s)
      end

      def self.bool_literal(b : Bool) : self
        new(Kind::BoolLiteral, b)
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

    # -----------------------
    # Tuple representation (matches listing 9.1)
    # -----------------------
    struct TupleRep(T)
      getter tag : ValAtom
      getter fields : Array(T)

      def initialize(@tag : ValAtom, @fields : Array(T))
      end
    end

    alias Tuple = TupleRep(ValAtom)
    alias Template = TupleRep(PatAtom)

    # -----------------------
    # Requests to the tuple-space server
    # -----------------------
    struct OutRequest
      getter tuple : Tuple

      def initialize(@tuple : Tuple)
      end
    end

    struct WaitRequest
      getter template : Template
      getter reply : Chan(Array(ValAtom))
      getter destructive : Bool
      getter id : Int64

      def initialize(@template : Template, @reply : Chan(Array(ValAtom)), @destructive : Bool, @id : Int64)
      end
    end

    struct CancelRequest
      getter id : Int64

      def initialize(@id : Int64)
      end
    end

    alias Request = OutRequest | WaitRequest | CancelRequest

    # -----------------------
    # Tuple space implemented with a server fiber and channels (CML style).
    # -----------------------
    class TupleSpace
      @req_chan : Chan(Request)
      @@waiter_counter = Atomic(Int64).new(0_i64)

      def initialize
        @req_chan = CML.channel(Request)
        spawn_server
      end

      # Put a tuple into the space (synchronous).
      def out(tuple : Tuple)
        CML.sync(@req_chan.send_evt(OutRequest.new(tuple)))
      end

      # inEvt: destructive read as an event.
      def in_evt(template : Template) : Event(Array(ValAtom))
        make_wait_event(template, destructive: true)
      end

      # rdEvt: non-destructive read as an event.
      def rd_evt(template : Template) : Event(Array(ValAtom))
        make_wait_event(template, destructive: false)
      end

      # Join tuple space (local only in this port).
      def self.join_tuple_space(local_port : Int32? = nil, remote_hosts : Array(String) = [] of String) : TupleSpace
        TupleSpace.new
      end

      private def spawn_server
        CML.spawn do
          tuples = [] of Tuple
          waiters = [] of WaitRequest

          loop do
            req = CML.sync(@req_chan.recv_evt)

            case req
            when OutRequest
              # Try to satisfy a waiter first
              matched_index = waiters.index do |w|
                ok, bindings = match_template(w.template, req.tuple)
                if ok
                  CML.sync(w.reply.send_evt(bindings))
                  true
                else
                  false
                end
              end

              if matched_index
                waiter = waiters.delete_at(matched_index)
                # If non-destructive, keep tuple; otherwise consume
                tuples << req.tuple unless waiter.destructive
              else
                tuples << req.tuple
              end
            when WaitRequest
              matched, bindings = try_match_existing(req.template, tuples, req.destructive)
              if matched
                CML.sync(req.reply.send_evt(bindings))
              else
                waiters << req
              end
            when CancelRequest
              waiters.reject! { |w| w.id == req.id }
            end
          end
        end
      end

      private def try_match_existing(template : Template, tuples : Array(Tuple), destructive : Bool) : {Bool, Array(ValAtom)}
        tuples.each_with_index do |t, idx|
          matched, bindings = match_template(template, t)
          if matched
            tuples.delete_at(idx) if destructive
            return {true, bindings}
          end
        end
        {false, [] of ValAtom}
      end

      private def match_template(template : Template, tuple : Tuple) : {Bool, Array(ValAtom)}
        bindings = [] of ValAtom

        return {false, bindings} unless template.tag == tuple.tag
        return {false, bindings} unless template.fields.size == tuple.fields.size

        template.fields.each_with_index do |pat, idx|
          val = tuple.fields[idx]
          case pat.kind
          when PatAtom::Kind::IntLiteral
            return {false, bindings} unless val.kind == ValAtom::Kind::Int && val.value == pat.value
          when PatAtom::Kind::StringLiteral
            return {false, bindings} unless val.kind == ValAtom::Kind::String && val.value == pat.value
          when PatAtom::Kind::BoolLiteral
            return {false, bindings} unless val.kind == ValAtom::Kind::Bool && val.value == pat.value
          when PatAtom::Kind::IntFormal
            return {false, bindings} unless val.kind == ValAtom::Kind::Int
            bindings << val
          when PatAtom::Kind::StringFormal
            return {false, bindings} unless val.kind == ValAtom::Kind::String
            bindings << val
          when PatAtom::Kind::BoolFormal
            return {false, bindings} unless val.kind == ValAtom::Kind::Bool
            bindings << val
          when PatAtom::Kind::Wild
            bindings << val
          end
        end

        {true, bindings}
      end

      private def make_wait_event(template : Template, destructive : Bool) : Event(Array(ValAtom))
        CML.with_nack do |nack|
          reply = CML.channel(Array(ValAtom))
          waiter_id = @@waiter_counter.add(1)
          # Send wait request to server
          CML.sync(@req_chan.send_evt(WaitRequest.new(template, reply, destructive, waiter_id)))

          # Cancel waiter if nack fires
          CML.spawn do
            CML.sync(nack)
            CML.sync(@req_chan.send_evt(CancelRequest.new(waiter_id)))
          end

          reply.recv_evt
        end
      end
    end

    # Helper constructors to mirror the SML interface.
    module Helpers
      def self.ival(i : Int32) : ValAtom
        ValAtom.int(i)
      end

      def self.sval(s : String) : ValAtom
        ValAtom.string(s)
      end

      def self.bval(b : Bool) : ValAtom
        ValAtom.bool(b)
      end

      def self.ipat(i : Int32) : PatAtom
        PatAtom.int_literal(i)
      end

      def self.spat(s : String) : PatAtom
        PatAtom.string_literal(s)
      end

      def self.bpat(b : Bool) : PatAtom
        PatAtom.bool_literal(b)
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
