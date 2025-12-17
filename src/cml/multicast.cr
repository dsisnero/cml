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
  # Internal state for the multicast message chain
  # Each MCState contains a message and an IVar pointing to the next state
  class MCState(T)
    getter value : T
    getter next_cv : IVar(MCState(T))

    def initialize(@value : T, @next_cv : IVar(MCState(T)))
    end
  end

  # Request types for the multicast server
  abstract struct MCRequest(T)
  end

  struct MCMessage(T) < MCRequest(T)
    getter value : T

    def initialize(@value : T)
    end
  end

  struct MCNewPort(T) < MCRequest(T)
  end

  # A port for receiving messages from a multicast channel
  # Each port has its own output channel and tracks its position in the stream
  class MCPort(T)
    @out_ch : Chan({T, IVar(MCState(T))})
    @state_var : MVar(IVar(MCState(T)))

    protected def initialize(@out_ch, @state_var)
    end

    # Blocking receive - get next message from this port
    def recv : T
      CML.sync(recv_evt)
    end

    # Receive event for use in choose/select
    def recv_evt : Event(T)
      MCPortRecvEvent(T).new(@out_ch, @state_var)
    end

    # Create a copy of this port at the same position in the stream
    # The copy will receive the same messages going forward
    def copy : MCPort(T)
      current_cv = @state_var.m_get
      MCPort.make_port(current_cv)
    end

    # Internal: create a new port starting at the given position
    protected def self.make_port(cv : IVar(MCState(T))) : MCPort(T) forall T
      out_ch = Chan({T, IVar(MCState(T))}).new
      state_var = MVar(IVar(MCState(T))).new(cv)

      # Spawn the "tee" fiber that forwards messages from the chain
      CML.spawn do
        tee_loop(cv, out_ch)
      end

      MCPort(T).new(out_ch, state_var)
    end

    # The tee loop reads from the IVar chain and sends to the output channel
    private def self.tee_loop(cv : IVar(MCState(T)), out_ch : Chan({T, IVar(MCState(T))})) forall T
      loop do
        state = cv.i_get
        out_ch.send({state.value, state.next_cv})
        cv = state.next_cv
      end
    end
  end

  # Receive event for MCPort
  # This is simpler - we just wrap the channel's recv_evt with a transformation
  class MCPortRecvEvent(T) < Event(T)
    @inner_evt : Event({T, IVar(MCState(T))})
    @state_var : MVar(IVar(MCState(T)))

    def initialize(out_ch : Chan({T, IVar(MCState(T))}), @state_var : MVar(IVar(MCState(T))))
      @inner_evt = out_ch.recv_evt
    end

    def poll : EventStatus(T)
      case status = @inner_evt.poll
      when Enabled({T, IVar(MCState(T))})
        value, next_cv = status.value
        @state_var.m_swap(next_cv)
        Enabled(T).new(priority: status.priority, value: value)
      when Blocked({T, IVar(MCState(T))})
        # For blocked, we need to wrap the block function
        inner_block = status.block_fn
        state_var = @state_var
        Blocked(T).new do |tid, next_fn|
          inner_block.call(tid, next_fn)
        end
      else
        raise "BUG: Unexpected poll status"
      end
    end

    protected def force_impl : EventGroup(T)
      # Use wrap to transform the inner event
      state_var = @state_var
      inner = @inner_evt

      # Get inner's force and wrap it
      inner_group = inner.force
      wrap_inner_group(inner_group, state_var)
    end

    private def wrap_inner_group(group : EventGroup({T, IVar(MCState(T))}), state_var : MVar(IVar(MCState(T)))) : EventGroup(T)
      case group
      when BaseGroup({T, IVar(MCState(T))})
        wrapped = group.events.map do |bevt|
          -> : EventStatus(T) {
            case status = bevt.call
            when Enabled({T, IVar(MCState(T))})
              value, next_cv = status.value
              state_var.m_swap(next_cv)
              Enabled(T).new(priority: status.priority, value: value).as(EventStatus(T))
            when Blocked({T, IVar(MCState(T))})
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
      when NestedGroup({T, IVar(MCState(T))})
        wrapped = group.groups.map { |g| wrap_inner_group(g, state_var) }
        NestedGroup(T).new(wrapped)
      when NackGroup({T, IVar(MCState(T))})
        NackGroup(T).new(group.cvar, wrap_inner_group(group.group, state_var))
      else
        raise "BUG: Unknown group type"
      end
    end
  end

  # Multicast channel - one sender, multiple receivers
  class MChan(T)
    @req_ch : Chan(MCRequest(T))
    @reply_ch : Chan(MCPort(T))

    protected def initialize(@req_ch, @reply_ch)
    end

    # Send a message to all ports
    def multicast(message : T)
      @req_ch.send(MCMessage(T).new(message))
    end

    # Create a new port for receiving messages
    # The port will receive all messages sent after it was created
    def port : MCPort(T)
      @req_ch.send(MCNewPort(T).new)
      @reply_ch.recv
    end

    # Create a new multicast channel
    def self.new : MChan(T) forall T
      req_ch = Chan(MCRequest(T)).new
      reply_ch = Chan(MCPort(T)).new

      # Spawn the server fiber
      CML.spawn do
        server_loop(req_ch, reply_ch, IVar(MCState(T)).new)
      end

      mchan = MChan(T).allocate
      mchan.initialize(req_ch, reply_ch)
      mchan
    end

    # Server loop that handles requests
    private def self.server_loop(
      req_ch : Chan(MCRequest(T)),
      reply_ch : Chan(MCPort(T)),
      cv : IVar(MCState(T)),
    ) forall T
      loop do
        case req = req_ch.recv
        when MCNewPort(T)
          # Create a new port at the current position
          port = MCPort.make_port(cv)
          reply_ch.send(port)
        when MCMessage(T)
          # Create new IVar for next message and complete current one
          next_cv = IVar(MCState(T)).new
          cv.i_put(MCState(T).new(req.value, next_cv))
          cv = next_cv
        end
      end
    end
  end

  # -----------------------
  # Public API
  # -----------------------

  # Create a new multicast channel
  def self.mchannel(type : T.class) : MChan(T) forall T
    MChan(T).new
  end

  # Send a message to all ports of a multicast channel
  def self.multicast(ch : MChan(T), message : T) forall T
    ch.multicast(message)
  end
end
