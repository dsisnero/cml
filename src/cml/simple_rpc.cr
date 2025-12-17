# Simple RPC - Generators for simple RPC protocols
#
# Port of SML/NJ CML's simple-rpc.sml
#
# This module provides utilities for creating simple request/response
# RPC (Remote Procedure Call) patterns using CML primitives.
#
# Four variants are provided:
# - mkRPC: Stateless RPC - function takes argument, returns result
# - mkRPC_In: RPC with input state - function takes (arg, state), returns result
# - mkRPC_Out: RPC with output state - function takes arg, returns (result, new_state)
# - mkRPC_InOut: RPC with input/output state - function takes (arg, state), returns (result, new_state)

require "../cml"

module RPC
  # Result of creating an RPC endpoint
  struct Endpoint(A, R)
    getter call : Proc(A, R)
    getter entry_evt : CML::Event(Nil)

    def initialize(@call, @entry_evt)
    end
  end

  struct EndpointIn(A, R, S)
    getter call : Proc(A, R)
    getter entry_evt : Proc(S, CML::Event(S))

    def initialize(@call, @entry_evt)
    end
  end

  struct EndpointOut(A, R, S)
    getter call : Proc(A, R)
    getter entry_evt : CML::Event(S)

    def initialize(@call, @entry_evt)
    end
  end

  struct EndpointInOut(A, R, S)
    getter call : Proc(A, R)
    getter entry_evt : Proc(S, CML::Event(S))

    def initialize(@call, @entry_evt)
    end
  end

  # Helper to safely put a value in an IVar (ignores if already set)
  private def self.safe_put(ivar : CML::IVar(T), value : T) forall T
    begin
      ivar.i_put(value)
    rescue CML::PutError
      # Already replied - ignore
    end
  end

  # Create a stateless RPC endpoint
  def self.mk_rpc(arg_type : A.class, result_type : R.class, &f : A -> R) : Endpoint(A, R) forall A, R
    req_ch = CML::Chan({A, CML::IVar(R)}).new

    call_fn = ->(arg : A) : R {
      reply_v = CML::IVar(R).new
      req_ch.send({arg, reply_v})
      reply_v.i_get
    }

    entry_evt = CML.wrap(req_ch.recv_evt) do |request|
      arg, reply_v = request
      result = f.call(arg)
      safe_put(reply_v, result)
      nil
    end

    Endpoint(A, R).new(call_fn, entry_evt)
  end

  # Create an RPC endpoint with input state
  def self.mk_rpc_in(arg_type : A.class, result_type : R.class, state_type : S.class, &f : A, S -> R) : EndpointIn(A, R, S) forall A, R, S
    req_ch = CML::Chan({A, CML::IVar(R)}).new

    call_fn = ->(arg : A) : R {
      reply_v = CML::IVar(R).new
      req_ch.send({arg, reply_v})
      reply_v.i_get
    }

    entry_evt_fn = ->(state : S) : CML::Event(S) {
      CML.wrap(req_ch.recv_evt) do |request|
        arg, reply_v = request
        result = f.call(arg, state)
        safe_put(reply_v, result)
        state
      end
    }

    EndpointIn(A, R, S).new(call_fn, entry_evt_fn)
  end

  # Create an RPC endpoint with output state
  def self.mk_rpc_out(arg_type : A.class, result_type : R.class, state_type : S.class, &f : A -> {R, S}) : EndpointOut(A, R, S) forall A, R, S
    req_ch = CML::Chan({A, CML::IVar(R)}).new

    call_fn = ->(arg : A) : R {
      reply_v = CML::IVar(R).new
      req_ch.send({arg, reply_v})
      reply_v.i_get
    }

    entry_evt = CML.wrap(req_ch.recv_evt) do |request|
      arg, reply_v = request
      result, new_state = f.call(arg)
      safe_put(reply_v, result)
      new_state
    end

    EndpointOut(A, R, S).new(call_fn, entry_evt)
  end

  # Create an RPC endpoint with input and output state
  def self.mk_rpc_in_out(arg_type : A.class, result_type : R.class, state_type : S.class, &f : A, S -> {R, S}) : EndpointInOut(A, R, S) forall A, R, S
    req_ch = CML::Chan({A, CML::IVar(R)}).new

    call_fn = ->(arg : A) : R {
      reply_v = CML::IVar(R).new
      req_ch.send({arg, reply_v})
      reply_v.i_get
    }

    entry_evt_fn = ->(state : S) : CML::Event(S) {
      CML.wrap(req_ch.recv_evt) do |request|
        arg, reply_v = request
        result, new_state = f.call(arg, state)
        safe_put(reply_v, result)
        new_state
      end
    }

    EndpointInOut(A, R, S).new(call_fn, entry_evt_fn)
  end

  # A simple RPC server that manages its own state and runs in a fiber
  class Server(A, R, S)
    @state : S
    @entry_evt_fn : Proc(S, CML::Event(S))
    @running = CML::AtomicFlag.new

    def initialize(@state : S, @entry_evt_fn : Proc(S, CML::Event(S)))
    end

    # Start the server in a new fiber
    def start : CML::ThreadId
      @running.set(true)
      CML.spawn do
        while @running.get
          @state = CML.sync(@entry_evt_fn.call(@state))
        end
      end
    end

    # Stop the server (it will stop after the current request completes)
    def stop
      @running.set(false)
    end

    # Get current state (for debugging/monitoring)
    def state : S
      @state
    end
  end
end

# -----------------------
# High-level convenience functions (CML API)
# -----------------------

module CML
  # Create a simple stateless RPC service
  def self.rpc_service(arg_type : A.class, result_type : R.class, &f : A -> R) : Proc(A, R) forall A, R
    rpc = ::RPC.mk_rpc(arg_type, result_type, &f)

    spawn do
      loop { CML.sync(rpc.entry_evt) }
    end

    rpc.call
  end

  # Create a stateful RPC service
  def self.stateful_rpc_service(
    arg_type : A.class,
    result_type : R.class,
    state_type : S.class,
    initial_state : S,
    &f : A, S -> {R, S}
  ) : Proc(A, R) forall A, R, S
    rpc = ::RPC.mk_rpc_in_out(arg_type, result_type, state_type, &f)

    spawn do
      state = initial_state
      loop { state = CML.sync(rpc.entry_evt.call(state)) }
    end

    rpc.call
  end
end
