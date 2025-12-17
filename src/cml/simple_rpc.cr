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

module CML
  # Result of creating an RPC endpoint
  # Contains the call function and the entry event for the server
  struct RPCEndpoint(A, R)
    getter call : Proc(A, R)
    getter entry_evt : Event(Nil)

    def initialize(@call, @entry_evt)
    end
  end

  # Result of creating an RPC endpoint with input state
  struct RPCEndpointIn(A, R, S)
    getter call : Proc(A, R)
    getter entry_evt : Proc(S, Event(S))

    def initialize(@call, @entry_evt)
    end
  end

  # Result of creating an RPC endpoint with output state
  struct RPCEndpointOut(A, R, S)
    getter call : Proc(A, R)
    getter entry_evt : Event(S)

    def initialize(@call, @entry_evt)
    end
  end

  # Result of creating an RPC endpoint with input/output state
  struct RPCEndpointInOut(A, R, S)
    getter call : Proc(A, R)
    getter entry_evt : Proc(S, Event(S))

    def initialize(@call, @entry_evt)
    end
  end

  module SimpleRPC
    # Helper to safely put a value in an IVar (ignores if already set)
    private def self.safe_put(ivar : IVar(T), value : T) forall T
      begin
        ivar.i_put(value)
      rescue PutError
        # Already replied - ignore
      end
    end

    # Create a stateless RPC endpoint
    def self.mk_rpc(arg_type : A.class, result_type : R.class, &f : A -> R) : RPCEndpoint(A, R) forall A, R
      # Use a Channel for RPC request/reply
      req_ch = Chan({A, IVar(R)}).new

      call_fn = ->(arg : A) : R {
        reply_v = IVar(R).new
        req_ch.send({arg, reply_v})
        reply_v.i_get
      }

      # Entry event wraps the channel receive and processes the request
      entry_evt = CML.wrap(req_ch.recv_evt) do |request|
        arg, reply_v = request
        result = f.call(arg)
        safe_put(reply_v, result)
        nil
      end

      RPCEndpoint(A, R).new(call_fn, entry_evt)
    end

    # Create an RPC endpoint with input state
    def self.mk_rpc_in(arg_type : A.class, result_type : R.class, state_type : S.class, &f : A, S -> R) : RPCEndpointIn(A, R, S) forall A, R, S
      req_ch = Chan({A, IVar(R)}).new

      call_fn = ->(arg : A) : R {
        reply_v = IVar(R).new
        req_ch.send({arg, reply_v})
        reply_v.i_get
      }

      entry_evt_fn = ->(state : S) : Event(S) {
        CML.wrap(req_ch.recv_evt) do |request|
          arg, reply_v = request
          result = f.call(arg, state)
          safe_put(reply_v, result)
          state
        end
      }

      RPCEndpointIn(A, R, S).new(call_fn, entry_evt_fn)
    end

    # Create an RPC endpoint with output state
    def self.mk_rpc_out(arg_type : A.class, result_type : R.class, state_type : S.class, &f : A -> {R, S}) : RPCEndpointOut(A, R, S) forall A, R, S
      req_ch = Chan({A, IVar(R)}).new

      call_fn = ->(arg : A) : R {
        reply_v = IVar(R).new
        req_ch.send({arg, reply_v})
        reply_v.i_get
      }

      entry_evt = CML.wrap(req_ch.recv_evt) do |request|
        arg, reply_v = request
        result, new_state = f.call(arg)
        safe_put(reply_v, result)
        new_state
      end

      RPCEndpointOut(A, R, S).new(call_fn, entry_evt)
    end

    # Create an RPC endpoint with input and output state
    def self.mk_rpc_in_out(arg_type : A.class, result_type : R.class, state_type : S.class, &f : A, S -> {R, S}) : RPCEndpointInOut(A, R, S) forall A, R, S
      req_ch = Chan({A, IVar(R)}).new

      call_fn = ->(arg : A) : R {
        reply_v = IVar(R).new
        req_ch.send({arg, reply_v})
        reply_v.i_get
      }

      entry_evt_fn = ->(state : S) : Event(S) {
        CML.wrap(req_ch.recv_evt) do |request|
          arg, reply_v = request
          result, new_state = f.call(arg, state)
          safe_put(reply_v, result)
          new_state
        end
      }

      RPCEndpointInOut(A, R, S).new(call_fn, entry_evt_fn)
    end
  end

  # -----------------------
  # Convenience class for stateful RPC servers
  # -----------------------

  # A simple RPC server that manages its own state and runs in a fiber
  class RPCServer(A, R, S)
    @state : S
    @entry_evt_fn : Proc(S, Event(S))
    @running = AtomicFlag.new

    def initialize(@state : S, @entry_evt_fn : Proc(S, Event(S)))
    end

    # Start the server in a new fiber
    def start : ThreadId
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

  # -----------------------
  # High-level convenience functions
  # -----------------------

  # Create a simple stateless RPC service
  #
  # Returns a proc that can be called to invoke the RPC.
  # Automatically starts a server fiber.
  #
  # Example:
  #   double = CML.rpc_service(Int32, Int32) { |n| n * 2 }
  #   double.call(21)  # => 42
  #
  def self.rpc_service(arg_type : A.class, result_type : R.class, &f : A -> R) : Proc(A, R) forall A, R
    rpc = SimpleRPC.mk_rpc(arg_type, result_type, &f)

    # Start server fiber
    spawn do
      loop { CML.sync(rpc.entry_evt) }
    end

    rpc.call
  end

  # Create a stateful RPC service
  #
  # Returns a proc that can be called to invoke the RPC.
  # Automatically starts a server fiber with the given initial state.
  #
  # Example:
  #   counter = CML.stateful_rpc_service(String, Int32, Int32, 0) { |cmd, count|
  #     case cmd
  #     when "inc" then {count + 1, count + 1}
  #     when "get" then {count, count}
  #     else {-1, count}
  #     end
  #   }
  #   counter.call("inc")  # => 1
  #   counter.call("inc")  # => 2
  #   counter.call("get")  # => 2
  #
  def self.stateful_rpc_service(
    arg_type : A.class,
    result_type : R.class,
    state_type : S.class,
    initial_state : S,
    &f : A, S -> {R, S}
  ) : Proc(A, R) forall A, R, S
    rpc = SimpleRPC.mk_rpc_in_out(arg_type, result_type, state_type, &f)

    # Start server fiber with state management
    spawn do
      state = initial_state
      loop { state = CML.sync(rpc.entry_evt.call(state)) }
    end

    rpc.call
  end
end
