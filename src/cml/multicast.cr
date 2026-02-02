# Multicast Channel - Asynchronous one-to-many communication
#
# Port of SML/NJ CML's multicast.sml
# See Chapter 5 of "Concurrent Programming in ML" for details.
#
# A multicast channel allows one sender to broadcast messages to multiple
# receivers. Each receiver (port) maintains its own position in the message
# stream, so receivers can be added at any time and will receive all future
# messages.
#
# Implementation uses a chain of IVars to represent the message stream.
# Each port has a "tee" fiber that forwards messages from the chain to the
# port's output channel.

require "../cml"

module CML
  module Multicast
    # Internal state for the multicast message chain
    # Each State contains a message and an IVar pointing to the next state
    class State(T)
      getter value : T
      getter next_cv : IVar(State(T))

      def initialize(@value : T, @next_cv : IVar(State(T)))
      end
    end

    # Request types for the multicast server
    abstract struct Request(T)
    end

    struct Message(T) < Request(T)
      getter value : T

      def initialize(@value : T)
      end
    end

    struct NewPort(T) < Request(T)
    end

    # A port for receiving messages from a multicast channel
    # Each port has its own output channel and tracks its position in the stream
    class Port(T)
      @out_ch : CML::Chan({T, IVar(State(T))})
      @state_var : MVar(IVar(State(T)))

      protected def initialize(@out_ch, @state_var)
      end

      # Blocking receive - get next message from this port
      def recv : T
        CML.sync(recv_evt)
      end

      # Receive event for use in choose/select
      def recv_evt : Event(T)
        PortRecvEvent(T).new(@out_ch, @state_var)
      end

      # Create a copy of this port at the same position in the stream
      # The copy will receive the same messages going forward
      def copy : Port(T)
        current_cv = @state_var.m_get
        Port.make_port(current_cv)
      end

      # Internal: create a new port starting at the given position
      protected def self.make_port(cv : IVar(State(T))) : Port(T) forall T
        out_ch = CML::Chan({T, IVar(State(T))}).new
        state_var = MVar(IVar(State(T))).new(cv)

        # Spawn the "tee" fiber that forwards messages from the chain
        CML.spawn do
          tee_loop(cv, out_ch)
        end

        Port(T).new(out_ch, state_var)
      end

      # The tee loop reads from the IVar chain and sends to the output channel
      private def self.tee_loop(cv : IVar(State(T)), out_ch : CML::Chan({T, IVar(State(T))})) forall T
        loop do
          state = cv.i_get
          out_ch.send({state.value, state.next_cv})
          cv = state.next_cv
        end
      end
    end

    # Receive event for Port
    # This is simpler - we just wrap the channel's recv_evt with a transformation
    class PortRecvEvent(T) < Event(T)
      @inner_evt : Event({T, IVar(State(T))})
      @state_var : MVar(IVar(State(T)))

      def initialize(out_ch : CML::Chan({T, IVar(State(T))}), @state_var : MVar(IVar(State(T))))
        @inner_evt = out_ch.recv_evt
      end

      def poll : EventStatus(T)
        case status = @inner_evt.poll
        when Enabled({T, IVar(State(T))})
          value, next_cv = status.value
          @state_var.m_swap(next_cv)
          Enabled(T).new(priority: status.priority, value: value)
        when Blocked({T, IVar(State(T))})
          inner_block = status.block_fn

          Blocked(T).new do |tid, next_fn|
            inner_block.call(tid, next_fn)
          end
        else
          raise "BUG: Unexpected poll status"
        end
      end

      protected def force_impl : EventGroup(T)
        state_var = @state_var
        inner = @inner_evt
        inner_group = inner.force
        wrap_inner_group(inner_group, state_var)
      end

      private def wrap_inner_group(group : EventGroup({T, IVar(State(T))}), state_var : MVar(IVar(State(T)))) : EventGroup(T)
        case group
        when BaseGroup({T, IVar(State(T))})
          wrapped = group.events.map do |bevt|
            -> : EventStatus(T) {
              case status = bevt.call
              when Enabled({T, IVar(State(T))})
                value, next_cv = status.value
                state_var.m_swap(next_cv)
                Enabled(T).new(priority: status.priority, value: value).as(EventStatus(T))
              when Blocked({T, IVar(State(T))})
                inner_block = status.block_fn
                Blocked(T).new { |tid, next_fn|
                  inner_block.call(tid, next_fn)
                }.as(EventStatus(T))
              else
                raise "BUG: Unexpected status"
              end
            }
          end
          BaseGroup(T).new(wrapped)
        when NestedGroup({T, IVar(State(T))})
          wrapped = group.groups.map { |g| wrap_inner_group(g, state_var) }
          NestedGroup(T).new(wrapped)
        when NackGroup({T, IVar(State(T))})
          NackGroup(T).new(group.cvar, wrap_inner_group(group.group, state_var))
        else
          raise "BUG: Unknown group type"
        end
      end
    end

    # Multicast channel - one sender, multiple receivers
    class Chan(T)
      @req_ch : CML::Chan(Request(T))
      @reply_ch : CML::Chan(Port(T))

      protected def initialize(@req_ch, @reply_ch)
      end

      # Send a message to all ports
      def multicast(message : T)
        @req_ch.send(Message(T).new(message))
      end

      # Create a new port for receiving messages
      # The port will receive all messages sent after it was created
      def port : Port(T)
        @req_ch.send(NewPort(T).new)
        @reply_ch.recv
      end

      # Create a new multicast channel
      def self.new : Chan(T) forall T
        req_ch = CML::Chan(Request(T)).new
        reply_ch = CML::Chan(Port(T)).new

        # Spawn the server fiber
        CML.spawn do
          server_loop(req_ch, reply_ch, IVar(State(T)).new)
        end

        mchan = Chan(T).allocate
        mchan.initialize(req_ch, reply_ch)
        mchan
      end

      # Server loop that handles requests
      private def self.server_loop(
        req_ch : CML::Chan(Request(T)),
        reply_ch : CML::Chan(Port(T)),
        cv : IVar(State(T)),
      ) forall T
        loop do
          case req = req_ch.recv
          when NewPort(T)
            port = Port.make_port(cv)
            reply_ch.send(port)
          when Message(T)
            next_cv = IVar(State(T)).new
            cv.i_put(State(T).new(req.value, next_cv))
            cv = next_cv
          end
        end
      end
    end
  end

  # -----------------------
  # Public API
  # -----------------------

  # Create a new multicast channel
  def self.mchannel(type : T.class) : Multicast::Chan(T) forall T
    Multicast::Chan(T).new
  end

  # Send a message to all ports of a multicast channel
  def self.multicast(ch : Multicast::Chan(T), message : T) forall T
    ch.multicast(message)
  end
end
