# src/cml/old_cml.cr
#
# Port of SML/NJ CML old-cml.sml to Crystal
# COPYRIGHT (c) 1990 by John H. Reppy. See COPYRIGHT file for details.
#
# This is essentially the 0.9.8 version of the core CML interface.
# Provides backward compatibility with the older CML API.
#
# SML signature:
#   structure OldCML : OLD_CML =
#     sig
#       val version : {major: int, minor: int, rev: int, date: string}
#       val versionName : string
#
#       type 'a event
#       val sync   : 'a event -> 'a
#       val select : 'a event list -> 'a
#       val choose : 'a event list -> 'a event
#       val guard  : (unit -> 'a event) -> 'a event
#       val wrap   : 'a event * ('a -> 'b) -> 'b event
#       val wrapHandler : 'a event * (exn -> 'a) -> 'a event
#       val wrapAbort : 'a event * (unit -> unit) -> 'a event
#       val always : 'a -> 'a event
#       val ALWAYS : unit event
#
#       type thread_id
#       val spawn : (unit -> unit) -> thread_id
#       val yield : unit -> unit
#       val exit  : unit -> 'a
#       val getTid : unit -> thread_id
#       val sameThread : thread_id * thread_id -> bool
#       val tidLessThan : thread_id * thread_id -> bool
#       val tidToString : thread_id -> string
#       val threadWait : thread_id -> unit event
#
#       type 'a cond_var
#       val condVar : unit -> 'a cond_var
#       val writeVar : 'a cond_var * 'a -> unit
#       exception WriteTwice
#       val readVar : 'a cond_var -> 'a
#       val readVarEvt : 'a cond_var -> 'a event
#
#       type 'a chan
#       val channel : unit -> 'a chan
#       val send   : 'a chan * 'a -> unit
#       val sendc  : 'a chan -> 'a -> unit
#       val accept : 'a chan -> 'a
#       val sameChannel : 'a chan * 'a chan -> bool
#       val transmit  : 'a chan * 'a -> unit event
#       val transmitc : 'a chan -> 'a -> unit event
#       val receive   : 'a chan -> 'a event
#
#       val waitUntil : Time -> unit event
#       val timeout   : Time.time -> unit event
#     end

require "../cml"
require "../ivar"

module CML
  # OldCML provides the classic 0.9.8 CML interface
  # for backward compatibility
  module OldCML
    # Version information
    VERSION      = {major: 1, minor: 0, rev: 0, date: "2024"}
    VERSION_NAME = "Crystal CML (OldCML compatibility layer)"

    # Exception for double-write on condition variables
    class WriteTwice < Exception
      def initialize
        super("Condition variable already written")
      end
    end

    # -----------------------
    # Event primitives
    # -----------------------

    # Synchronize on an event
    # Equivalent to SML's: val sync : 'a event -> 'a
    def self.sync(evt : Event(T)) : T forall T
      CML.sync(evt)
    end

    # Select from a list of events (sync on choose)
    # Equivalent to SML's: val select : 'a event list -> 'a
    def self.select(evts : Array(Event(T))) : T forall T
      CML.sync(CML.choose(evts))
    end

    # Choose from a list of events
    # Equivalent to SML's: val choose : 'a event list -> 'a event
    def self.choose(evts : Array(Event(T))) : Event(T) forall T
      CML.choose(evts)
    end

    # Guard an event (defer creation until sync)
    # Equivalent to SML's: val guard : (unit -> 'a event) -> 'a event
    def self.guard(&block : -> Event(T)) : Event(T) forall T
      CML.guard(&block)
    end

    # Wrap an event with a transformation function
    # Equivalent to SML's: val wrap : 'a event * ('a -> 'b) -> 'b event
    def self.wrap(evt : Event(A), &block : A -> B) : Event(B) forall A, B
      CML.wrap(evt, &block)
    end

    # Wrap an event with an exception handler
    # Equivalent to SML's: val wrapHandler : 'a event * (exn -> 'a) -> 'a event
    def self.wrap_handler(evt : Event(T), &handler : Exception -> T) : Event(T) forall T
      WrapHandlerEvt(T).new(evt, handler)
    end

    # Wrap an event with an abort action (like nack but runs abort on cancel)
    # Equivalent to SML's:
    #   fun wrapAbort (evt, abortAct) = CML.withNack (fn abortEvt => let
    #       fun abortAct' () = (sync abortEvt; abortAct())
    #     in
    #       CML.spawn abortAct'; evt
    #     end
    def self.wrap_abort(evt : Event(T), &abort_act : -> Nil) : Event(T) forall T
      CML.wrap_abort(evt, abort_act) { |x| x }
    end

    # An event that always succeeds with the given value
    # Equivalent to SML's: val always : 'a -> 'a event
    def self.always(x : T) : Event(T) forall T
      CML.always(x)
    end

    # An event that always succeeds with nil
    # Equivalent to SML's: val ALWAYS : unit event
    def self.always_unit : Event(Nil)
      CML.always(nil)
    end

    ALWAYS = always_unit

    # -----------------------
    # Thread primitives
    # -----------------------

    # Thread ID is just a Fiber in Crystal
    alias ThreadId = Fiber

    # Spawn a new fiber
    # Equivalent to SML's: val spawn : (unit -> unit) -> thread_id
    def self.spawn(&block : -> Nil) : ThreadId
      ::spawn { block.call }
    end

    # Yield the current fiber
    # Equivalent to SML's: val yield : unit -> unit
    def self.yield_fiber
      Fiber.yield
    end

    # Exit the current fiber
    # Equivalent to SML's: val exit : unit -> 'a
    def self.exit_fiber
      Fiber.yield # Crystal doesn't have a direct fiber exit
      raise "Fiber exit"
    end

    # Get the current thread ID
    # Equivalent to SML's: val getTid : unit -> thread_id
    def self.get_tid : ThreadId
      Fiber.current
    end

    # Check if two thread IDs are the same
    # Equivalent to SML's: val sameThread : thread_id * thread_id -> bool
    def self.same_thread(tid1 : ThreadId, tid2 : ThreadId) : Bool
      tid1 == tid2
    end

    # Compare thread IDs (for ordering)
    # Equivalent to SML's: val tidLessThan : thread_id * thread_id -> bool
    def self.tid_less_than(tid1 : ThreadId, tid2 : ThreadId) : Bool
      tid1.object_id < tid2.object_id
    end

    # Convert thread ID to string
    # Equivalent to SML's: val tidToString : thread_id -> string
    def self.tid_to_string(tid : ThreadId) : String
      tid.name || "fiber-#{tid.object_id}"
    end

    # Event that completes when a thread terminates
    # Equivalent to SML's: val threadWait : thread_id -> unit event
    # Note: Crystal doesn't have a direct fiber join event, so we poll
    def self.thread_wait(tid : ThreadId) : Event(Nil)
      FiberJoinEvt.new(tid)
    end

    # -----------------------
    # Condition variables (IVars)
    # -----------------------

    # Condition variable is just an IVar
    alias CondVar = IVar

    # Create a new condition variable
    # Equivalent to SML's: val condVar : unit -> 'a cond_var
    def self.cond_var(type : T.class) : CondVar(T) forall T
      IVar(T).new
    end

    # Write to a condition variable (only once)
    # Equivalent to SML's: val writeVar : 'a cond_var * 'a -> unit
    def self.write_var(cv : CondVar(T), value : T) forall T
      cv.fill(value)
    rescue
      raise WriteTwice.new
    end

    # Read from a condition variable (blocking)
    # Equivalent to SML's: val readVar : 'a cond_var -> 'a
    def self.read_var(cv : CondVar(T)) : T forall T
      cv.read
    end

    # Event for reading from a condition variable
    # Equivalent to SML's: val readVarEvt : 'a cond_var -> 'a event
    def self.read_var_evt(cv : CondVar(T)) : Event(T) forall T
      cv.read_evt
    end

    # -----------------------
    # Channels
    # -----------------------

    # Create a new channel
    # Equivalent to SML's: val channel : unit -> 'a chan
    def self.channel(type : T.class) : Chan(T) forall T
      Chan(T).new
    end

    # Send on a channel (blocking)
    # Equivalent to SML's: val send : 'a chan * 'a -> unit
    def self.send(ch : Chan(T), msg : T) forall T
      CML.sync(ch.send_evt(msg))
    end

    # Curried send
    # Equivalent to SML's: val sendc : 'a chan -> 'a -> unit
    def self.sendc(ch : Chan(T)) : Proc(T, Nil) forall T
      ->(msg : T) { send(ch, msg); nil }
    end

    # Receive from a channel (blocking)
    # Equivalent to SML's: val accept : 'a chan -> 'a
    def self.accept(ch : Chan(T)) : T forall T
      CML.sync(ch.recv_evt)
    end

    # Check if two channels are the same
    # Equivalent to SML's: val sameChannel : 'a chan * 'a chan -> bool
    def self.same_channel(ch1 : Chan(T), ch2 : Chan(T)) : Bool forall T
      ch1 == ch2
    end

    # Send event (transmit)
    # Equivalent to SML's: val transmit : 'a chan * 'a -> unit event
    def self.transmit(ch : Chan(T), msg : T) : Event(Nil) forall T
      ch.send_evt(msg)
    end

    # Curried transmit
    # Equivalent to SML's: val transmitc : 'a chan -> 'a -> unit event
    def self.transmitc(ch : Chan(T)) : Proc(T, Event(Nil)) forall T
      ->(msg : T) { ch.send_evt(msg) }
    end

    # Receive event
    # Equivalent to SML's: val receive : 'a chan -> 'a event
    def self.receive(ch : Chan(T)) : Event(T) forall T
      ch.recv_evt
    end

    # -----------------------
    # Real-time synchronization
    # -----------------------

    # Event that fires at a specific time
    # Equivalent to SML's: val waitUntil : Time -> unit event
    def self.wait_until(time : Time) : Event(Symbol)
      duration = time - Time.utc
      if duration.positive?
        CML.timeout(duration)
      else
        CML.always(:timeout)
      end
    end

    # Timeout event (fires after a duration)
    # Equivalent to SML's: val timeout : Time.time -> unit event
    def self.timeout(duration : Time::Span) : Event(Symbol)
      CML.timeout(duration)
    end
  end

  # -----------------------
  # Internal helper events
  # -----------------------

  # Event that wraps another event with exception handling
  private class WrapHandlerEvt(T) < Event(T)
    def initialize(@inner : Event(T), @handler : Proc(Exception, T))
    end

    def try_register(pick : Pick(T)) : Proc(Nil)
      inner_pick = Pick(T).new
      cancel_inner = @inner.try_register(inner_pick)
      spawn do
        begin
          inner_pick.wait
          if inner_pick.decided?
            pick.try_decide(inner_pick.value)
          end
        rescue ex
          pick.try_decide(@handler.call(ex))
        end
      end
      cancel_inner
    end
  end

  # Event that waits for a fiber to terminate
  # Note: Crystal doesn't have built-in fiber join, so we poll
  private class FiberJoinEvt < Event(Nil)
    def initialize(@fiber : Fiber)
    end

    def try_register(pick : Pick(Nil)) : Proc(Nil)
      spawn do
        # Poll for fiber death
        loop do
          if @fiber.dead?
            pick.try_decide(nil)
            break
          end
          sleep 10.milliseconds
        end
      end
      -> { }
    end
  end
end