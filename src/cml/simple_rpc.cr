# src/cml/simple_rpc.cr
#
# Port of SML/NJ CML simple-rpc.sml to Crystal
# COPYRIGHT (c) 1997 AT&T Labs Research.
#
# Generators for simple RPC protocols.
#
# SML signature:
#   structure SimpleRPC : SIMPLE_RPC =
#     sig
#       type 'a event = 'a CML.event
#
#       val mkRPC : ('a -> 'b) -> {
#           call : 'a -> 'b,
#           entryEvt : unit event
#         }
#
#       val mkRPC_In : ('a * 's -> 'b) -> {
#           call : 'a -> 'b,
#           entryEvt : 's -> unit event
#         }
#
#       val mkRPC_Out : ('a -> 'b * 's) -> {
#           call : 'a -> 'b,
#           entryEvt : 's event
#         }
#
#       val mkRPC_InOut : ('a * 's -> 'b * 's) -> {
#           call : 'a -> 'b,
#           entryEvt : 's -> 's event
#         }
#     end

require "../cml"
require "../ivar"
require "./mailbox"

module CML
  # Result type for simple RPC (no state)
  # Contains a call function and an entry event for the server
  class RPC(A, B)
    getter call : Proc(A, B)
    getter entry_evt : Event(Nil)

    def initialize(@call : Proc(A, B), @entry_evt : Event(Nil))
    end
  end

  # Result type for RPC with input state
  # Contains a call function and an entry event factory that takes state
  class RPCIn(A, B, S)
    getter call : Proc(A, B)
    getter entry_evt : Proc(S, Event(Nil))

    def initialize(@call : Proc(A, B), @entry_evt : Proc(S, Event(Nil)))
    end
  end

  # Result type for RPC with output state
  # Contains a call function and an entry event that produces state
  class RPCOut(A, B, S)
    getter call : Proc(A, B)
    getter entry_evt : Event(S)

    def initialize(@call : Proc(A, B), @entry_evt : Event(S))
    end
  end

  # Result type for RPC with input/output state
  # Contains a call function and an entry event factory that transforms state
  class RPCInOut(A, B, S)
    getter call : Proc(A, B)
    getter entry_evt : Proc(S, Event(S))

    def initialize(@call : Proc(A, B), @entry_evt : Proc(S, Event(S)))
    end
  end

  # Internal helper: performs the call by sending request and waiting for reply
  # Equivalent to SML's:
  #   fun call reqMB arg = let
  #     val replV = SyncVar.iVar()
  #   in
  #     Mailbox.send(reqMB, (arg, replV));
  #     SyncVar.iGet replV
  #   end
  private def self.rpc_call(req_mb : Mailbox(Tuple(A, IVar(B))), arg : A) : B forall A, B
    reply_v = IVar(B).new
    req_mb.send({arg, reply_v})
    reply_v.read
  end

  # Create a simple stateless RPC
  # Equivalent to SML's:
  #   fun mkRPC f = let
  #     val reqMB = Mailbox.mailbox()
  #     val entryEvt = CML.wrap (
  #       Mailbox.recvEvt reqMB,
  #       fn (arg, replV) => SyncVar.iPut(replV, f arg))
  #   in
  #     { call = call reqMB, entryEvt = entryEvt }
  #   end
  def self.mk_rpc(f : Proc(A, B)) : RPC(A, B) forall A, B
    req_mb = Mailbox(Tuple(A, IVar(B))).new

    call_fn = ->(arg : A) { rpc_call(req_mb, arg) }

    entry_evt = wrap(req_mb.recv_evt) do |request|
      arg, reply_v = request
      reply_v.fill(f.call(arg))
      nil
    end

    RPC(A, B).new(call_fn, entry_evt)
  end

  # Create an RPC with input state
  # Equivalent to SML's:
  #   fun mkRPC_In f = let
  #     val reqMB = Mailbox.mailbox()
  #     val reqEvt = Mailbox.recvEvt reqMB
  #     fun entryEvt state = CML.wrap (
  #       reqEvt,
  #       fn (arg, replV) => SyncVar.iPut(replV, f(arg, state)))
  #   in
  #     { call = call reqMB, entryEvt = entryEvt }
  #   end
  def self.mk_rpc_in(f : Proc(A, S, B)) : RPCIn(A, B, S) forall A, B, S
    req_mb = Mailbox(Tuple(A, IVar(B))).new
    req_evt = req_mb.recv_evt

    call_fn = ->(arg : A) { rpc_call(req_mb, arg) }

    entry_evt_fn = ->(state : S) {
      wrap(req_evt) do |request|
        arg, reply_v = request
        reply_v.fill(f.call(arg, state))
        nil
      end
    }

    RPCIn(A, B, S).new(call_fn, entry_evt_fn)
  end

  # Create an RPC with output state
  # Equivalent to SML's:
  #   fun mkRPC_Out f = let
  #     val reqMB = Mailbox.mailbox()
  #     val reqEvt = Mailbox.recvEvt reqMB
  #     val entryEvt = CML.wrap (
  #       reqEvt,
  #       fn (arg, replV) => let val (res, state') = f arg
  #         in
  #           SyncVar.iPut(replV, res); state'
  #         end)
  #   in
  #     { call = call reqMB, entryEvt = entryEvt }
  #   end
  def self.mk_rpc_out(f : Proc(A, Tuple(B, S))) : RPCOut(A, B, S) forall A, B, S
    req_mb = Mailbox(Tuple(A, IVar(B))).new
    req_evt = req_mb.recv_evt

    call_fn = ->(arg : A) { rpc_call(req_mb, arg) }

    entry_evt = wrap(req_evt) do |request|
      arg, reply_v = request
      result, state_out = f.call(arg)
      reply_v.fill(result)
      state_out
    end

    RPCOut(A, B, S).new(call_fn, entry_evt)
  end

  # Create an RPC with input/output state
  # Equivalent to SML's:
  #   fun mkRPC_InOut f = let
  #     val reqMB = Mailbox.mailbox()
  #     val reqEvt = Mailbox.recvEvt reqMB
  #     fun entryEvt state = CML.wrap (
  #       reqEvt,
  #       fn (arg, replV) => let val (res, state') = f(arg, state)
  #         in
  #           SyncVar.iPut(replV, res); state'
  #         end)
  #   in
  #     { call = call reqMB, entryEvt = entryEvt }
  #   end
  def self.mk_rpc_in_out(f : Proc(A, S, Tuple(B, S))) : RPCInOut(A, B, S) forall A, B, S
    req_mb = Mailbox(Tuple(A, IVar(B))).new
    req_evt = req_mb.recv_evt

    call_fn = ->(arg : A) { rpc_call(req_mb, arg) }

    entry_evt_fn = ->(state : S) {
      wrap(req_evt) do |request|
        arg, reply_v = request
        result, state_out = f.call(arg, state)
        reply_v.fill(result)
        state_out
      end
    }

    RPCInOut(A, B, S).new(call_fn, entry_evt_fn)
  end
end
