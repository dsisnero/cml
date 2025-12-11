# src/cml/multicast_sml.cr
#
# Port of SML/NJ CML multicast.sml to Crystal
# COPYRIGHT (c) 1994 AT&T Bell Laboratories.
#
# Asynchronous multicast (one-to-many) channels. This implementation
# is based on a condition variable implementation of multicast channels.
# See Chapter 5 of "Concurrent Programming in ML" for details.
#
# SML signature:
#   structure Multicast : MULTICAST =
#     sig
#       type 'a mchan
#       type 'a port
#       val mChannel : unit -> 'a mchan
#       val multicast : 'a mchan * 'a -> unit
#       val port : 'a mchan -> 'a port
#       val copy : 'a port -> 'a port
#       val recv : 'a port -> 'a
#       val recvEvt : 'a port -> 'a event
#     end

require "../cml"
require "../ivar"
require "../mvar"

module CML
  # State cell holding a message and pointer to the next state.
  # Equivalent to SML's: datatype 'a mc_state = MCState of ('a * 'a mc_state V.ivar)
  class MCState(T)
    getter value : T
    getter next_cv : IVar(MCState(T))

    def initialize(@value : T, @next_cv : IVar(MCState(T)))
    end
  end

  # Request types for the multicast server
  # Equivalent to SML's: datatype 'a request = Message of 'a | NewPort
  module MulticastRequest(T)
    record Message(T), value : T
    record NewPort(T)
  end

  # A port for receiving multicast messages.
  # Equivalent to SML's:
  #   and 'a port = Port of (('a * 'a mc_state V.ivar) CML.chan * 'a mc_state V.ivar V.mvar)
  class MulticastPort(T)
    @out_ch : Chan(Tuple(T, IVar(MCState(T))))
    @state_var : MVar(IVar(MCState(T)))

    def initialize(cv : IVar(MCState(T)))
      @out_ch = Chan(Tuple(T, IVar(MCState(T)))).new
      @state_var = MVar(IVar(MCState(T))).new
      init_state_var(cv)
      start_tee_fiber(cv)
    end

    private def init_state_var(cv : IVar(MCState(T)))
      # Initialize the MVar with the current state pointer
      # Equivalent to: val stateVar = V.mVarInit cv
      @state_var.put(cv)
    end

    private def start_tee_fiber(cv : IVar(MCState(T)))
      # Start the tee fiber that forwards messages
      # Equivalent to SML's:
      #   fun tee cv = let
      #     val (MCState(v, nextCV)) = V.iGet cv
      #   in
      #     CML.send (outCh, (v, nextCV));
      #     tee nextCV
      #   end
      spawn do
        tee(cv)
      end
    end

    private def tee(cv : IVar(MCState(T)))
      loop do
        state = cv.read
        # Send the value and next state pointer to the output channel
        CML.sync(@out_ch.send_evt({state.value, state.next_cv}))
        cv = state.next_cv
      end
    end

    # Receive a message from this port (blocking)
    # Equivalent to SML's: fun recv (Port(ch, stateV)) = recvMsg stateV (CML.recv ch)
    def recv : T
      CML.sync(recv_evt)
    end

    # Event for receiving a message from this port
    # Equivalent to SML's: fun recvEvt (Port(ch, stateV)) = CML.wrap(CML.recvEvt ch, recvMsg stateV)
    def recv_evt : Event(T)
      CML.wrap(@out_ch.recv_evt) do |pair|
        value, next_cv = pair
        # Update state to point to next message
        # Equivalent to: fun recvMsg stateV (v, nextCV) = (V.mSwap (stateV, nextCV); v)
        @state_var.swap(next_cv)
        value
      end
    end

    # Get the out channel (for internal use)
    protected def out_ch
      @out_ch
    end

    # Get the state var (for internal use)
    protected def state_var
      @state_var
    end
  end

  # A multicast channel that can broadcast messages to multiple ports.
  # Equivalent to SML's: datatype 'a mchan = MChan of ('a request CML.chan * 'a port CML.chan)
  class MulticastChan(T)
    @req_ch : Chan(MulticastRequest::Message(T) | MulticastRequest::NewPort(T))
    @reply_ch : Chan(MulticastPort(T))

    def initialize
      @req_ch = Chan(MulticastRequest::Message(T) | MulticastRequest::NewPort(T)).new
      @reply_ch = Chan(MulticastPort(T)).new
      start_server
    end

    private def start_server
      # Start the server fiber
      # Equivalent to SML's:
      #   fun server cv = (case (CML.recv reqCh)
      #      of NewPort => (
      #           CML.send (replyCh, mkPort cv);
      #           server cv)
      #       | (Message m) => let
      #           val nextCV = V.iVar()
      #         in
      #           V.iPut (cv, MCState(m, nextCV));
      #           server nextCV
      #         end
      #     (* end case *))
      spawn do
        cv = IVar(MCState(T)).new
        server(cv)
      end
    end

    private def server(cv : IVar(MCState(T)))
      loop do
        req = CML.sync(@req_ch.recv_evt)
        case req
        when MulticastRequest::Message(T)
          # Create next state cell and fill current one
          next_cv = IVar(MCState(T)).new
          cv.fill(MCState(T).new(req.value, next_cv))
          cv = next_cv
        when MulticastRequest::NewPort(T)
          # Create and return a new port pointing to current state
          port = make_port(cv)
          CML.sync(@reply_ch.send_evt(port))
        end
      end
    end

    private def make_port(cv : IVar(MCState(T))) : MulticastPort(T)
      MulticastPort(T).new(cv)
    end

    # Broadcast a message to all ports
    # Equivalent to SML's: fun multicast (MChan(ch, _), m) = CML.send (ch, Message m)
    def multicast(msg : T)
      CML.sync(@req_ch.send_evt(MulticastRequest::Message(T).new(msg)))
    end

    # Create a new port for receiving messages
    # Equivalent to SML's:
    #   fun port (MChan(reqCh, replyCh)) = (
    #     CML.send (reqCh, NewPort);
    #     CML.recv replyCh)
    def port : MulticastPort(T)
      CML.sync(@req_ch.send_evt(MulticastRequest::NewPort(T).new))
      CML.sync(@reply_ch.recv_evt)
    end
  end

  # Copy a port to create a new port starting from the same position
  # Equivalent to SML's: fun copy (Port(_, stateV)) = mkPort(V.mGet stateV)
  def self.copy_port(port : MulticastPort(T)) : MulticastPort(T) forall T
    current_cv = port.state_var.get
    MulticastPort(T).new(current_cv)
  end

  # Module-level convenience functions matching SML API

  # Create a new multicast channel
  # Equivalent to SML's: val mChannel : unit -> 'a mchan
  def self.m_channel_sml(type : T.class) : MulticastChan(T) forall T
    MulticastChan(T).new
  end

  # Broadcast a message on a multicast channel
  # Equivalent to SML's: val multicast : 'a mchan * 'a -> unit
  def self.multicast_sml(chan : MulticastChan(T), msg : T) forall T
    chan.multicast(msg)
  end

  # Create a new port on a multicast channel
  # Equivalent to SML's: val port : 'a mchan -> 'a port
  def self.port_sml(chan : MulticastChan(T)) : MulticastPort(T) forall T
    chan.port
  end

  # Copy a port
  # Equivalent to SML's: val copy : 'a port -> 'a port
  def self.copy_sml(port : MulticastPort(T)) : MulticastPort(T) forall T
    copy_port(port)
  end

  # Receive from a port (blocking)
  # Equivalent to SML's: val recv : 'a port -> 'a
  def self.recv_sml(port : MulticastPort(T)) : T forall T
    port.recv
  end

  # Event for receiving from a port
  # Equivalent to SML's: val recvEvt : 'a port -> 'a event
  def self.recv_evt_sml(port : MulticastPort(T)) : Event(T) forall T
    port.recv_evt
  end
end
