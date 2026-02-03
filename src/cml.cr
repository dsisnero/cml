# CML - Improved Crystal CML implementation

require "./ext/io_wait_readable"
require "./cml/sync"
require "./timer_wheel"
require "./trace_macro"
require "atomic"

#
# This implementation is more closely aligned with SML/NJ CML semantics
# and uses Crystal's native fiber facilities more efficiently.
#
# Key improvements over cml.cr:
# 1. Two-phase poll/block protocol matching SML/NJ
# 2. Direct fiber suspension instead of spawning helper fibers
# 3. Lock-free transaction ID pattern for cancellation
# 4. Proper priority-based selection for fairness

module CML
  # Version information matching SML/NJ CML signature
  VERSION = {
    system:     "Crystal CML",
    version_id: [0, 5, 0],
    date:       "2026-01-29",
  }

  # Banner string for identification
  BANNER = "Crystal Concurrent ML Runtime v0.5.0"

  # Accessor methods for compatibility with SML/NJ CML signature
  def self.version : NamedTuple(system: String, version_id: Array(Int32), date: String)
    VERSION
  end

  def self.banner : String
    BANNER
  end

  # -----------------------
  # Transaction ID
  # -----------------------
  # Represents the state of a blocked operation.
  # Based on SML/NJ's trans_id type.
  enum TransactionState
    Active    # Transaction is still valid
    Committed # Transaction completed successfully
    Cancelled # Transaction was cancelled (another branch won)
  end

  # Transaction ID for tracking blocked operations
  # This replaces the Pick class for better efficiency
  class TransactionId
    @state : Atomic(TransactionState)
    @fiber : Fiber?
    @cleanup : Proc(Nil)?

    # Unique ID for tracing/debugging
    getter id : Int64

    @@id_counter = Atomic(Int64).new(0_i64)

    def initialize
      @state = Atomic(TransactionState).new(TransactionState::Active)
      @fiber = nil
      @cleanup = nil
      @id = @@id_counter.add(1)
    end

    def active? : Bool
      @state.get == TransactionState::Active
    end

    def cancelled? : Bool
      @state.get == TransactionState::Cancelled
    end

    # Try to cancel this transaction
    # Returns true if successfully cancelled, false if already cancelled or committed
    def try_cancel : Bool
      CML.trace "TransactionId.try_cancel", id, @state.get, tag: "transaction"
      _, success = @state.compare_and_set(TransactionState::Active, TransactionState::Cancelled)
      if success && (cleanup = @cleanup)
        CML.trace "TransactionId.try_cancel success", id, tag: "transaction"
        cleanup.call
      else
        CML.trace "TransactionId.try_cancel already committed/cancelled", id, @state.get, tag: "transaction"
      end
      success
    end

    # Set the cleanup action to run when this transaction is cancelled
    def set_cleanup(@cleanup : Proc(Nil)?)
    end

    # Set the fiber to resume when this transaction commits
    def set_fiber(@fiber : Fiber)
    end

    # Try to commit and resume the associated fiber
    # Returns true if this call successfully committed (and resumed), false if already committed/cancelled
    def try_commit_and_resume : Bool
      CML.trace "TransactionId.try_commit_and_resume", id, @state.get, tag: "transaction"
      _, success = @state.compare_and_set(TransactionState::Active, TransactionState::Committed)
      if success
        CML.trace "TransactionId.try_commit_and_resume success", id, @fiber, tag: "transaction"
        @fiber.try(&.enqueue)
      else
        CML.trace "TransactionId.try_commit_and_resume already committed/cancelled", id, @state.get, tag: "transaction"
      end
      success
    end

    # Resume the associated fiber (deprecated - use try_commit_and_resume)
    def resume_fiber
      try_commit_and_resume
    end
  end

  # -----------------------
  # Event Status (poll result)
  # -----------------------
  # Represents the result of polling an event.
  # Matches SML/NJ's event_status datatype.
  abstract struct EventStatus(T)
  end

  # Event is immediately ready with a value
  struct Enabled(T) < EventStatus(T)
    getter priority : Int32
    getter value : T

    def initialize(@priority : Int32, @value : T)
    end
  end

  # Event needs to block
  struct Blocked(T) < EventStatus(T)
    # The block function receives transaction info and a next function
    # It should register for wakeup and call next() to continue
    getter block_fn : Proc(TransactionId, Proc(Nil), Nil)

    def initialize(&@block_fn : TransactionId, Proc(Nil) -> Nil)
    end
  end

  # -----------------------
  # Base Event
  # -----------------------
  # A base event is a pollable function that returns event status.
  # This matches SML/NJ's base_evt type.
  # Note: Crystal doesn't support generic aliases, so we use the Proc type directly

  # -----------------------
  # Event (abstract)
  # -----------------------
  # The main event type - can be:
  # - BEVT: list of base events
  # - CHOOSE: choice of events
  # - GUARD: lazy event creation
  # - WITH_NACK: event with negative acknowledgment

  abstract class Event(T)
    # Unique event id for tracing
    property event_id : Int64 = 0_i64

    # Poll the event - check if it's immediately ready
    abstract def poll : EventStatus(T)

    # Force evaluation of guards, returning an event group
    def force : EventGroup(T)
      force_impl
    end

    protected abstract def force_impl : EventGroup(T)
  end

  # -----------------------
  # Event Group (forced events)
  # -----------------------
  # After forcing guards, we get an event group.
  # Matches SML/NJ's event_group datatype.
  abstract class EventGroup(T)
  end

  # Base group - flat list of base events (poll functions)
  class BaseGroup(T) < EventGroup(T)
    getter events : Array(Proc(EventStatus(T)))

    def initialize(@events : Array(Proc(EventStatus(T))))
    end

    def initialize(event : Proc(EventStatus(T)))
      @events = [event]
    end

    def empty? : Bool
      @events.empty?
    end
  end

  # Nested group of event groups
  class NestedGroup(T) < EventGroup(T)
    getter groups : Array(EventGroup(T))

    def initialize(@groups : Array(EventGroup(T)))
    end
  end

  # Nack group - group with negative acknowledgment
  class NackGroup(T) < EventGroup(T)
    getter cvar : CVar
    getter group : EventGroup(T)

    def initialize(@cvar : CVar, @group : EventGroup(T))
    end
  end

  # -----------------------
  # Basic Events
  # -----------------------

  # An event that always succeeds immediately with a value
  class AlwaysEvent(T) < Event(T)
    def initialize(@value : T)
    end

    def poll : EventStatus(T)
      Enabled(T).new(priority: -1, value: @value)
    end

    protected def force_impl : EventGroup(T)
      BaseGroup(T).new(-> : EventStatus(T) { poll })
    end
  end

  # An event that never succeeds
  class NeverEvent(T) < Event(T)
    def poll : EventStatus(T)
      Blocked(T).new { |_, _| } # Block forever, never resume
    end

    protected def force_impl : EventGroup(T)
      BaseGroup(T).new(Array(Proc(EventStatus(T))).new) # Empty base group
    end
  end

  # Slot for passing values between fibers (works with any type)
  class Slot(T)
    @value : T?
    @has_value = false
    @mtx = Sync::Mutex.new

    def initialize
      @value = nil
    end

    def set(value : T)
      @mtx.synchronize do
        @value = value
        @has_value = true
      end
    end

    def has_value? : Bool
      @mtx.synchronize { @has_value }
    end

    def get : T
      @mtx.synchronize do
        raise "Slot has no value" unless @has_value
        @value.as(T)
      end
    end

    # Atomically check if value is present and return it
    # Returns {true, value} if present, {false, nil} if not
    def get_if_present : {Bool, T?}
      @mtx.synchronize do
        if @has_value
          {true, @value}
        else
          {false, nil}
        end
      end
    end
  end

  # Wrapper for atomic bool (reference type, not struct)
  class AtomicFlag
    @value = Atomic(Bool).new(false)

    def get : Bool
      @value.get
    end

    def set(val : Bool)
      @value.set(val)
    end

    # Atomically compare and set the flag
    def compare_and_set(expected : Bool, desired : Bool) : Bool
      _, success = @value.compare_and_set(expected, desired)
      success
    end

    # Get with acquire memory ordering (ensures subsequent reads see writes from the thread that set the flag)
    def get_with_acquire : Bool
      Atomic::Ops.fence(:acquire, false)
      @value.get
    end

    # Set with release memory ordering (ensures previous writes are visible to threads that subsequently get with acquire)
    def set_with_release(val : Bool)
      @value.set(val)
      Atomic::Ops.fence(:release, false)
    end
  end

  # -----------------------
  # Running Flag
  # -----------------------
  # Tracks whether CML is currently running.
  # Based on SML/NJ's Running.isRunning flag.
  # Starts true for backward compatibility (CML available without explicit run).
  @@is_running : AtomicFlag = AtomicFlag.new.tap(&.set(true))

  # -----------------------
  # Channel
  # -----------------------
  # Synchronous rendezvous channel matching SML/NJ semantics.
  # Uses a simpler approach: waiting operations store their completion state
  # in a mutable Result slot that the counterpart fills in during rendezvous.
  class Chan(T)
    @closed = Atomic(Bool).new(false)

    # Waiting senders: {value, send_done, transaction_id}
    # send_done is set to true when rendezvous completes
    # NOTE: AtomicFlag is a class (reference type) so it shares state properly
    @send_q = Deque({T, AtomicFlag, TransactionId}).new

    # Waiting receivers: {recv_slot, recv_done, transaction_id}
    # recv_slot holds the received value, recv_done signals completion
    @recv_q = Deque({Slot(T), AtomicFlag, TransactionId}).new

    @mtx = Sync::Mutex.new

    def close
      @closed.set(true)
    end

    def closed? : Bool
      @closed.get
    end

    # Reset channel to initial state (clears pending queues)
    def reset : Nil
      @mtx.synchronize do
        @closed.set(false)
        @send_q.clear
        @recv_q.clear
      end
    end

    # Identity comparison
    # SML: val sameChannel : ('a chan * 'a chan) -> bool
    def same?(other : Chan(T)) : Bool
      object_id == other.object_id
    end

    # Blocking send
    def send(value : T) : Nil
      CML.sync(send_evt(value))
    end

    # Blocking receive
    def recv : T
      CML.sync(recv_evt)
    end

    # Non-blocking send poll - returns true if send succeeded immediately
    # SML: val sendPoll : ('a chan * 'a) -> bool
    def send_poll(value : T) : Bool
      @mtx.synchronize do
        # Check for waiting receiver
        while entry = @recv_q.shift?
          recv_slot, recv_done, recv_tid = entry
          next if recv_tid.cancelled?

          # Found active receiver - complete rendezvous
          recv_slot.set(value)
          recv_done.set(true)
          recv_tid.resume_fiber
          return true
        end

        # No receiver available
        false
      end
    end

    # Non-blocking receive poll - returns value if available
    # SML: val recvPoll : 'a chan -> 'a option
    def recv_poll : T?
      @mtx.synchronize do
        # Check for waiting sender
        while entry = @send_q.shift?
          value, send_done, send_tid = entry
          next if send_tid.cancelled?

          # Found active sender - complete rendezvous
          send_done.set(true)
          send_tid.resume_fiber
          return value
        end

        # No sender available
        nil
      end
    end

    # Create a send event
    def send_evt(value : T) : Event(Nil)
      SendEvent(T).new(self, value)
    end

    # Create a receive event
    def recv_evt : Event(T)
      RecvEvent(T).new(self)
    end

    # Create poll function for send operation
    protected def make_send_poll(value : T) : Proc(EventStatus(Nil))
      chan = self
      send_done = AtomicFlag.new

      -> : EventStatus(Nil) {
        chan.@mtx.synchronize do
          # Fast path: already complete from previous poll
          if send_done.get
            return Enabled(Nil).new(priority: 0, value: nil)
          end

          # Check for waiting receiver
          while entry = chan.@recv_q.shift?
            recv_slot, recv_done, recv_tid = entry
            next if recv_tid.cancelled?

            # Found active receiver - complete rendezvous
            recv_slot.set(value)
            recv_done.set(true)
            send_done.set(true)
            recv_tid.resume_fiber

            return Enabled(Nil).new(priority: 0, value: nil)
          end

          # No receiver - need to block (or already blocked)
          Blocked(Nil).new do |tid, next_fn|
            chan.@send_q << {value, send_done, tid}
            tid.set_cleanup -> { chan.remove_send(tid.id) }
            next_fn.call
          end
        end
      }
    end

    # Create poll function for receive operation
    protected def make_recv_poll : {Proc(EventStatus(T)), Slot(T)}
      chan = self
      recv_slot = Slot(T).new
      recv_done = AtomicFlag.new

      poll_fn = -> : EventStatus(T) {
        chan.@mtx.synchronize do
          # Fast path: already complete from previous poll
          if recv_done.get
            has_val, val = recv_slot.get_if_present
            if has_val
              return Enabled(T).new(priority: 0, value: val.as(T))
            end
          end

          # Check for waiting sender
          while entry = chan.@send_q.shift?
            value, send_done, send_tid = entry
            next if send_tid.cancelled?

            # Found active sender - complete rendezvous
            recv_slot.set(value)
            recv_done.set(true)
            send_done.set(true)
            send_tid.resume_fiber

            return Enabled(T).new(priority: 0, value: value)
          end

          # No sender - need to block (or already blocked)
          Blocked(T).new do |tid, next_fn|
            chan.@recv_q << {recv_slot, recv_done, tid}
            tid.set_cleanup -> { chan.remove_recv(tid.id) }
            next_fn.call
          end
        end
      }

      {poll_fn, recv_slot}
    end

    # Remove a send from the queue (called during cleanup)
    protected def remove_send(tid_id : Int64)
      @mtx.synchronize { @send_q.reject! { |_, _, t| t.id == tid_id } }
    end

    # Remove a recv from the queue (called during cleanup)
    protected def remove_recv(tid_id : Int64)
      @mtx.synchronize { @recv_q.reject! { |_, _, t| t.id == tid_id } }
    end
  end

  # Send event
  class SendEvent(T) < Event(Nil)
    @poll_fn : Proc(EventStatus(Nil))

    def initialize(@ch : Chan(T), value : T)
      @poll_fn = @ch.make_send_poll(value)
    end

    def poll : EventStatus(Nil)
      @poll_fn.call
    end

    protected def force_impl : EventGroup(Nil)
      BaseGroup(Nil).new(@poll_fn)
    end
  end

  # Receive event
  class RecvEvent(T) < Event(T)
    @poll_fn : Proc(EventStatus(T))

    def initialize(@ch : Chan(T))
      @poll_fn, _ = @ch.make_recv_poll
    end

    def poll : EventStatus(T)
      @poll_fn.call
    end

    protected def force_impl : EventGroup(T)
      BaseGroup(T).new(@poll_fn)
    end
  end

  # -----------------------
  # Wrap Event
  # -----------------------
  # Transforms the result of an event
  class WrapEvent(A, B) < Event(B)
    def initialize(@inner : Event(A), &@f : A -> B)
    end

    def poll : EventStatus(B)
      case status = @inner.poll
      when Enabled(A)
        Enabled(B).new(priority: status.priority, value: @f.call(status.value))
      when Blocked(A)
        inner_block = status.block_fn
        Blocked(B).new do |tid, next_fn|
          inner_block.call(tid, next_fn)
        end
      else
        raise "BUG: Unexpected event status type"
      end
    end

    protected def force_impl : EventGroup(B)
      # Wrap each base event in the inner group
      wrap_group(@inner.force)
    end

    private def wrap_group(group : EventGroup(A)) : EventGroup(B)
      case group
      when BaseGroup(A)
        f = @f
        wrapped = group.events.map do |bevt|
          -> : EventStatus(B) {
            case status = bevt.call
            when Enabled(A)
              Enabled(B).new(priority: status.priority, value: f.call(status.value)).as(EventStatus(B))
            when Blocked(A)
              inner_block = status.block_fn
              Blocked(B).new { |tid, next_fn|
                inner_block.call(tid, next_fn)
              }.as(EventStatus(B))
            else
              raise "BUG: Unexpected status"
            end
          }
        end
        BaseGroup(B).new(wrapped)
      when NestedGroup(A)
        wrapped = group.groups.map { |g| wrap_group(g) }
        NestedGroup(B).new(wrapped)
      when NackGroup(A)
        NackGroup(B).new(group.cvar, wrap_group(group.group))
      else
        raise "BUG: Unknown group type"
      end
    end
  end

  # -----------------------
  # Wrap Handler Event
  # -----------------------
  # Wraps an event with exception handling.
  # If the wrapped event's action raises an exception during sync,
  # the handler is called to produce an alternative value.
  # SML: val wrapHandler : ('a event * (exn -> 'a)) -> 'a event
  class WrapHandlerEvent(T) < Event(T)
    def initialize(@inner : Event(T), &@handler : Exception -> T)
    end

    def poll : EventStatus(T)
      case status = @inner.poll
      when Enabled(T)
        status
      when Blocked(T)
        inner_block = status.block_fn
        Blocked(T).new do |tid, next_fn|
          inner_block.call(tid, next_fn)
        end
      else
        raise "BUG: Unexpected event status type"
      end
    rescue ex : Exception
      Enabled(T).new(priority: -1, value: @handler.call(ex))
    end

    protected def force_impl : EventGroup(T)
      # Wrap each base event in the inner group with exception handling
      # Also catch exceptions during force (e.g., from guard blocks)

      wrap_handler_group(@inner.force)
    rescue ex : Exception
      # Return a base group with a single "always enabled with handler result" event
      BaseGroup(T).new(-> : EventStatus(T) {
        Enabled(T).new(priority: -1, value: @handler.call(ex))
      })
    end

    private def wrap_handler_group(group : EventGroup(T)) : EventGroup(T)
      case group
      when BaseGroup(T)
        handler = @handler
        wrapped = group.events.map do |bevt|
          -> : EventStatus(T) {
            begin
              bevt.call
            rescue ex : Exception
              Enabled(T).new(priority: -1, value: handler.call(ex))
            end
          }
        end
        BaseGroup(T).new(wrapped)
      when NestedGroup(T)
        wrapped = group.groups.map { |g| wrap_handler_group(g) }
        NestedGroup(T).new(wrapped)
      when NackGroup(T)
        NackGroup(T).new(group.cvar, wrap_handler_group(group.group))
      else
        raise "BUG: Unknown group type"
      end
    end
  end

  # -----------------------
  # Guard Event
  # -----------------------
  # Defers event creation until sync time
  class GuardEvent(T) < Event(T)
    @thunk : -> Event(T)

    def initialize(&block : -> E) forall E
      # Capture the block and wrap it to return Event(T)
      @thunk = -> : Event(T) { block.call.as(Event(T)) }
    end

    def poll : EventStatus(T)
      @thunk.call.poll
    end

    protected def force_impl : EventGroup(T)
      @thunk.call.force
    end
  end

  # -----------------------
  # Choose Event
  # -----------------------
  # Choice between multiple events
  class ChooseEvent(T) < Event(T)
    getter events : Array(Event(T))

    def initialize(events : Array)
      @events = events.map(&.as(Event(T)))
    end

    def poll : EventStatus(T)
      # Poll all events, return first enabled
      @events.each do |evt|
        case status = evt.poll
        when Enabled(T)
          return status
        end
      end

      # All blocked - need to block on all
      Blocked(T).new do |tid, next_fn|
        # This is simplified - real implementation needs to register all
        @events.each do |evt|
          case status = evt.poll
          when Blocked(T)
            status.block_fn.call(tid, next_fn)
            return
          end
        end
      end
    end

    protected def force_impl : EventGroup(T)
      # Force all child events and combine
      # Note: We need to cast each result to EventGroup(T) because when events
      # are of different concrete types (e.g., RecvEvent from different channels),
      # the map would return EventGroup(T)+ (union type)
      forced = @events.map { |e| e.force.as(EventGroup(T)) }

      # Flatten nested groups
      result = Array(EventGroup(T)).new
      forced.each do |g|
        case g
        when BaseGroup(T)
          if !g.empty?
            result << g
          end
        when NestedGroup(T)
          result.concat(g.groups)
        else
          result << g
        end
      end

      case result.size
      when 0
        BaseGroup(T).new(Array(Proc(EventStatus(T))).new)
      when 1
        result.first
      else
        NestedGroup(T).new(result)
      end
    end
  end

  # -----------------------
  # WithNack Event
  # -----------------------
  # Event with negative acknowledgment
  class WithNackEvent(T) < Event(T)
    @f : Proc(Event(Nil), Event(T))

    def initialize(&block : Event(Nil) -> E) forall E
      @f = ->(nack_evt : Event(Nil)) : Event(T) { block.call(nack_evt).as(Event(T)) }
    end

    def poll : EventStatus(T)
      # Create nack event and call user function
      cvar = CVar.new
      nack_evt = CVar::Event.new(cvar)
      inner = @f.call(nack_evt)
      inner.poll
    end

    protected def force_impl : EventGroup(T)
      cvar = CVar.new
      nack_evt = CVar::Event.new(cvar)
      inner = @f.call(nack_evt)
      NackGroup(T).new(cvar, inner.force)
    end
  end

  # -----------------------
  # Timeout Event
  # -----------------------
  class TimeoutEvent < Event(Nil)
    @duration : Time::Span
    @ready = AtomicFlag.new
    @cancel_flag = AtomicFlag.new
    @started = false
    @start_mtx = Sync::Mutex.new
    @timer_id : UInt64?

    def initialize(duration : Time::Span)
      @duration = duration
    end

    def poll : EventStatus(Nil)
      if @ready.get
        return Enabled(Nil).new(priority: 0, value: nil)
      end

      Blocked(Nil).new do |tid, next_fn|
        start_once(tid)
        tid.set_cleanup -> { cancel_timer }
        next_fn.call
      end
    end

    protected def force_impl : EventGroup(Nil)
      BaseGroup(Nil).new(-> : EventStatus(Nil) { poll })
    end

    private def start_once(tid : TransactionId)
      should_start = false

      @start_mtx.synchronize do
        unless @started
          @started = true
          should_start = true
        end
      end

      return unless should_start

      @timer_id = self.class.timer_wheel.schedule(@duration) do
        deliver(tid)
      end
    end

    private def cancel_timer
      if id = @timer_id
        self.class.timer_wheel.cancel(id)
      end
      @cancel_flag.set(true)
    end

    private def deliver(tid : TransactionId)
      return if @cancel_flag.get
      @ready.set(true)
      tid.try_commit_and_resume
    end

    def self.timer_wheel
      @@timer_wheel ||= TimerWheel.new
    end
  end

  # -----------------------
  # AtTime Event
  # -----------------------
  # Event that fires at an absolute time
  # SML: val atTimeEvt : Time.time -> unit event
  class AtTimeEvent < Event(Nil)
    @poll_fn : Proc(EventStatus(Nil))

    def initialize(target_time : Time)
      timeout_done = AtomicFlag.new

      @poll_fn = -> : EventStatus(Nil) {
        # Fast path: timer already fired
        if timeout_done.get
          return Enabled(Nil).new(priority: 0, value: nil)
        end

        # Check if time has already passed
        now = Time.utc
        if now >= target_time
          timeout_done.set(true)
          return Enabled(Nil).new(priority: 0, value: nil)
        end

        duration = target_time - now

        Blocked(Nil).new do |tid, next_fn|
          # Schedule timer to resume fiber
          spawn do
            sleep duration
            unless tid.cancelled?
              timeout_done.set(true)
              tid.resume_fiber
            end
          end
          next_fn.call
        end
      }
    end

    def poll : EventStatus(Nil)
      @poll_fn.call
    end

    protected def force_impl : EventGroup(Nil)
      BaseGroup(Nil).new(@poll_fn)
    end
  end

  # -----------------------
  # Sync Implementation
  # -----------------------

  # Synchronize on an event - the core CML operation
  def self.sync(evt : Event(T)) : T forall T
    CML.trace "CML.sync start", evt.class, tag: "sync"
    unless running?
      raise "CML is not running (call CML.run first)"
    end
    group = evt.force
    CML.trace "CML.sync force complete", tag: "sync"
    sync_on_group(group)
  end

  # Sync on a forced event group
  private def self.sync_on_group(group : EventGroup(T)) : T forall T
    case group
    when BaseGroup(T)
      sync_on_base_events(group.events)
    else
      sync_on_complex_group(group)
    end
  end

  # Sync on a list of base events (no nacks)
  private def self.sync_on_base_events(events : Array(Proc(EventStatus(T)))) : T forall T
    CML.trace "sync_on_base_events start", events.size, tag: "sync"
    return sync_never(T) if events.empty?
    return sync_on_one(events.first) if events.size == 1

    # Try to find an enabled event
    blocked = Array({Proc(EventStatus(T)), Blocked(T)}).new

    events.each do |bevt|
      case status = bevt.call
      when Enabled(T)
        CML.trace "sync_on_base_events found enabled", tag: "sync"
        return status.value
      when Blocked(T)
        blocked << {bevt, status}
      end
    end

    CML.trace "sync_on_base_events all blocked", blocked.size, tag: "sync"

    # All events are blocked - register all and wait
    tid = TransactionId.new
    tid.set_fiber(Fiber.current)
    CML.trace "sync_on_base_events tid created", tid.id, tag: "sync"

    blocked.each do |_, status|
      status.block_fn.call(tid, -> { })
    end

    CML.trace "sync_on_base_events before suspend", tag: "sync"
    Fiber.suspend
    CML.trace "sync_on_base_events after suspend", tag: "sync"

    # Find which event triggered
    events.each do |bevt|
      case status = bevt.call
      when Enabled(T)
        CML.trace "sync_on_base_events post-suspend enabled", tag: "sync"
        return status.value
      end
    end

    CML.trace "sync_on_base_events no event ready after resume", tag: "sync"
    raise "BUG: Fiber resumed but no event is ready"
  end

  # Sync on a single base event
  private def self.sync_on_one(bevt : Proc(EventStatus(T))) : T forall T
    CML.trace "sync_on_one start", tag: "sync"
    case status = bevt.call
    when Enabled(T)
      CML.trace "sync_on_one enabled", status.value, tag: "sync"
      status.value
    when Blocked(T)
      CML.trace "sync_on_one blocked", tag: "sync"
      tid = TransactionId.new
      tid.set_fiber(Fiber.current)
      CML.trace "sync_on_one before block_fn", tid.id, tag: "sync"
      status.block_fn.call(tid, -> { })
      CML.trace "sync_on_one before suspend", tag: "sync"
      Fiber.suspend
      CML.trace "sync_on_one after suspend", tag: "sync"

      # Re-poll after waking
      case status2 = bevt.call
      when Enabled(T)
        CML.trace "sync_on_one after suspend enabled", status2.value, tag: "sync"
        status2.value
      else
        CML.trace "sync_on_one after suspend not enabled", tag: "sync"
        raise "BUG: Fiber resumed but event not ready"
      end
    else
      CML.trace "sync_on_one unknown status", tag: "sync"
      raise "BUG: Unknown status type"
    end
  end

  # Sync on a complex group with nacks
  private def self.sync_on_complex_group(group : EventGroup(T)) : T forall T
    # Collect base events and nack cvars
    events_with_flags = [] of {Proc(EventStatus(T)), AtomicFlag}
    nack_sets = [] of {CVar, Array(AtomicFlag)}

    collect_events(group, events_with_flags, nack_sets, [] of AtomicFlag)

    # Try polling first
    events_with_flags.each do |(bevt, flag)|
      case status = bevt.call
      when Enabled(T)
        flag.set(true)
        fire_nacks(nack_sets)
        return status.value
      end
    end

    # All blocked - register everything
    tid = TransactionId.new
    tid.set_fiber(Fiber.current)

    events_with_flags.each do |(bevt, flag)|
      case status = bevt.call
      when Blocked(T)
        status.block_fn.call(tid, -> { })
      end
    end

    Fiber.suspend

    # Find winner and fire nacks
    events_with_flags.each do |(bevt, flag)|
      case status = bevt.call
      when Enabled(T)
        flag.set(true)
        fire_nacks(nack_sets)
        return status.value
      end
    end

    raise "BUG: Fiber resumed but no event ready"
  end

  # Collect base events from a group, tracking flags for nack handling
  private def self.collect_events(
    group : EventGroup(T),
    result : Array({Proc(EventStatus(T)), AtomicFlag}),
    nack_sets : Array({CVar, Array(AtomicFlag)}),
    current_flags : Array(AtomicFlag),
  ) forall T
    case group
    when BaseGroup(T)
      group.events.each do |bevt|
        flag = AtomicFlag.new
        result << {bevt, flag}
        current_flags << flag
      end
    when NestedGroup(T)
      group.groups.each do |g|
        collect_events(g, result, nack_sets, current_flags)
      end
    when NackGroup(T)
      branch_flags = [] of AtomicFlag
      collect_events(group.group, result, nack_sets, branch_flags)
      nack_sets << {group.cvar, branch_flags}
      current_flags.concat(branch_flags)
    end
  end

  # Fire nack cvars for branches that didn't win
  private def self.fire_nacks(nack_sets : Array({CVar, Array(AtomicFlag)}))
    nack_sets.each do |(cvar, flags)|
      # If none of the flags are set, this branch lost
      unless flags.any?(&.get)
        cvar.set!
      end
    end
  end

  # Sync on never - blocks forever
  private def self.sync_never(t : T.class) : T forall T
    Fiber.suspend
    raise "BUG: Never event should not resume"
  end

  # ===========================================================================
  # IVar - Write-Once Synchronization Variable (SML/NJ compatible)
  # ===========================================================================
  # An IVar (I-structure variable) can only be written once.
  # Subsequent writes raise an exception.
  # Reads block until the value is available, then return it.
  #
  # SML signature:
  #   val iVar : unit -> 'a ivar
  #   val sameIVar : ('a ivar * 'a ivar) -> bool
  #   val iPut : ('a ivar * 'a) -> unit
  #   val iGet : 'a ivar -> 'a
  #   val iGetEvt : 'a ivar -> 'a event
  #   val iGetPoll : 'a ivar -> 'a option

  class PutError < Exception
    def initialize
      super("IVar/MVar already has a value")
    end
  end

  # -----------------------
  # Public API
  # -----------------------

  # Check if CML is running
  # SML: val isRunning : bool ref
  def self.running? : Bool
    @@is_running.get
  end

  # Set CML running state (for initialization/shutdown)
  # Internal use - called by RunCML equivalent
  def self.set_running(state : Bool) : Nil
    @@is_running.set(state)
  end

  # Run CML with initial procedure (similar to SML/NJ RunCML.doit)
  # Sets running flag, calls cleanup AtInit, runs block, ensures cleanup AtShutdown
  def self.run(&block : -> Nil) : Nil
    if running?
      raise "CML is already running"
    end
    set_running(true)
    Cleanup.clean_all(Cleanup::When::AtInit)
    begin
      block.call
    ensure
      Cleanup.clean_all(Cleanup::When::AtShutdown)
      set_running(false)
    end
  end

  # Shutdown CML (similar to SML/NJ RunCML.shutdown)
  def self.shutdown : NoReturn
    unless running?
      raise "CML is not running"
    end
    Cleanup.clean_all(Cleanup::When::AtShutdown)
    set_running(false)
    exit # exit current thread
  end

  def self.always(x : T) : Event(T) forall T
    AlwaysEvent(T).new(x)
  end

  def self.never(type : T.class) : Event(T) forall T
    NeverEvent(T).new
  end

  def self.never : Event(Nil)
    NeverEvent(Nil).new
  end

  def self.wrap(evt : Event(A), &f : A -> B) : Event(B) forall A, B
    WrapEvent(A, B).new(evt, &f)
  end

  def self.guard(&block : -> Event(T)) : Event(T) forall T
    GuardEvent(T).new(&block)
  end

  def self.choose(events : Array(Event(T))) : Event(T) forall T
    case events.size
    when 0
      NeverEvent(T).new
    when 1
      events.first
    else
      ChooseEvent(T).new(events)
    end
  end

  def self.choose(*events : Event(T)) : Event(T) forall T
    choose(events.to_a)
  end

  def self.with_nack(&f : Event(Nil) -> Event(T)) : Event(T) forall T
    WithNackEvent(T).new(&f)
  end

  # Add a nack handler to an existing event
  def self.nack(evt : Event(T), &block : -> Nil) : Event(T) forall T
    with_nack do |nack_evt|
      ::spawn do
        CML.sync(nack_evt)
        block.call
      end
      evt
    end
  end

  def self.timeout(duration : Time::Span) : Event(Nil)
    TimeoutEvent.new(duration)
  end

  # -----------------------
  # DSL helpers
  # -----------------------

  # Fire after the given duration, then evaluate the block.
  def self.after(duration : Time::Span, &block : -> T) : Event(T) forall T
    wrap(timeout(duration)) { block.call }
  end

  # Event that spawns a fiber when synchronized and returns its thread id.
  def self.spawn_evt(&block : -> Nil) : Event(Thread::Id)
    guard do
      AlwaysEvent(Thread::Id).new(spawn(&block))
    end
  end

  # -----------------------
  # Sleep helper
  # -----------------------

  def self.sleep(duration : Time::Span)
    sync(timeout(duration))
  end

  def self.select(events : Array(Event(T))) : T forall T
    sync(choose(events))
  end

  def self.channel(type : T.class) : Chan(T) forall T
    Chan(T).new
  end

  # -----------------------
  # Mailbox API
  # -----------------------

  def self.mailbox(type : T.class) : Mailbox(T) forall T
    Mailbox(T).new
  end

  def self.same_mailbox(m1 : Mailbox(T), m2 : Mailbox(T)) : Bool forall T
    m1.same?(m2)
  end

  # -----------------------
  # IVar API
  # -----------------------

  def self.ivar(type : T.class) : IVar(T) forall T
    IVar(T).new
  end

  def self.same_ivar(v1 : IVar(T), v2 : IVar(T)) : Bool forall T
    v1.same?(v2)
  end

  # -----------------------
  # MVar API
  # -----------------------

  def self.mvar(type : T.class) : MVar(T) forall T
    MVar(T).new
  end

  def self.mvar_init(value : T) : MVar(T) forall T
    MVar(T).new(value)
  end

  def self.same_mvar(v1 : MVar(T), v2 : MVar(T)) : Bool forall T
    v1.same?(v2)
  end

  # -----------------------
  # Channel API (additional)
  # -----------------------

  def self.same_channel(c1 : Chan(T), c2 : Chan(T)) : Bool forall T
    c1.same?(c2)
  end

  # -----------------------
  # Event API (additional)
  # -----------------------

  # Wrap an event with exception handling
  # SML: val wrapHandler : ('a event * (exn -> 'a)) -> 'a event
  def self.wrap_handler(evt : Event(T), &handler : Exception -> T) : Event(T) forall T
    WrapHandlerEvent(T).new(evt, &handler)
  end

  # Event that fires at an absolute time
  # SML: val atTimeEvt : Time.time -> unit event
  def self.at_time(target_time : Time) : Event(Nil)
    AtTimeEvent.new(target_time)
  end

  # -----------------------
  # Thread API
  # -----------------------

  # Get current thread ID
  # SML: val getTid : unit -> thread_id
  def self.get_tid : Thread::Id
    Thread::Id.current
  end

  # Compare thread IDs for equality
  # SML: val sameTid : (thread_id * thread_id) -> bool
  def self.same_tid(t1 : Thread::Id, t2 : Thread::Id) : Bool
    t1.same?(t2)
  end

  # Compare thread IDs for ordering
  # SML: val compareTid : (thread_id * thread_id) -> order
  def self.compare_tid(t1 : Thread::Id, t2 : Thread::Id) : Int32
    t1 <=> t2
  end

  # Hash a thread ID
  # SML: val hashTid : thread_id -> word
  def self.hash_tid(tid : Thread::Id) : UInt64
    tid.hash
  end

  # Convert thread ID to string
  # SML: val tidToString : thread_id -> string
  def self.tid_to_string(tid : Thread::Id) : String
    tid.to_s
  end

  # Spawn a new thread
  # SML: val spawn : (unit -> unit) -> thread_id
  def self.spawn(&block : -> Nil) : Thread::Id
    unless running?
      raise "CML is not running (call CML.run first)"
    end
    # Create a slot to hold the ThreadId reference
    tid_slot = Slot(Thread::Id).new
    fiber = ::spawn do
      begin
        block.call
      ensure
        if tid_slot.has_value?
          tid_slot.get.mark_exited
        end
      end
    end
    tid = Thread::Id.new(fiber)
    tid_slot.set(tid)
    tid
  end

  # Spawn a new thread with an argument
  # SML: val spawnc : ('a -> unit) -> 'a -> thread_id
  def self.spawnc(arg : A, &block : A -> Nil) : Thread::Id forall A
    unless running?
      raise "CML is not running (call CML.run first)"
    end
    tid_slot = Slot(Thread::Id).new
    fiber = ::spawn do
      begin
        block.call(arg)
      ensure
        if tid_slot.has_value?
          tid_slot.get.mark_exited
        end
      end
    end
    tid = Thread::Id.new(fiber)
    tid_slot.set(tid)
    tid
  end

  # Exit current thread
  # SML: val exit : unit -> 'a
  def self.exit : NoReturn
    tid = Thread::Id.for_fiber(Fiber.current)
    tid.try(&.mark_exited)
    raise Thread::Exit.new
  end

  # Event that fires when a thread exits
  # SML: val joinEvt : thread_id -> unit event
  def self.join_evt(tid : Thread::Id) : Event(Nil)
    tid.join_evt
  end

  # Yield to other threads
  # SML: val yield : unit -> unit
  def self.yield
    Fiber.yield
  end

  # -----------------------
  # Thread-Local Storage API
  # -----------------------

  # Create a new thread property with lazy initialization
  # SML: val newThreadProp : (unit -> 'a) -> {...}
  def self.new_thread_prop(type : T.class, &init : -> T) : Thread::Prop(T) forall T
    Thread::Prop(T).new(&init)
  end

  # Create a new thread flag (boolean thread-local)
  # SML: val newThreadFlag : unit -> {...}
  def self.new_thread_flag : Thread::Flag
    Thread::Flag.new
  end

  # -----------------------
  # DSL helpers
  # -----------------------

  # Fire after the given duration, then evaluate the block.
  def self.after(duration : Time::Span, &block : -> T) : Event(T) forall T
    wrap(timeout(duration)) { block.call }
  end

  # Event that spawns a fiber when synchronized and returns its thread id.
  def self.spawn_evt(&block : -> Nil) : Event(Thread::Id)
    guard do
      AlwaysEvent(Thread::Id).new(spawn(&block))
    end
  end

  # -----------------------
  # Sleep helper
  # -----------------------

  def self.sleep(duration : Time::Span)
    sync(timeout(duration))
  end

  # -----------------------
  # Process helper events
  # -----------------------

  # Event that executes a system command and completes with its exit status.
  def self.system_evt(command : String) : Event(::Process::Status)
    with_nack do |nack|
      SystemCommandEvent.new(command, nack)
    end
  end

  # Run a system command synchronously using an event under the hood.
  def self.system(command : String) : ::Process::Status
    sync(system_evt(command))
  end

  def self.select(events : Array(Event(T))) : T forall T
    sync(choose(events))
  end

  def self.channel(type : T.class) : Chan(T) forall T
    Chan(T).new
  end

  # -----------------------
  # Mailbox API
  # -----------------------

  def self.mailbox(type : T.class) : Mailbox(T) forall T
    Mailbox(T).new
  end

  def self.same_mailbox(m1 : Mailbox(T), m2 : Mailbox(T)) : Bool forall T
    m1.same?(m2)
  end

  # -----------------------
  # IVar API
  # -----------------------

  def self.ivar(type : T.class) : IVar(T) forall T
    IVar(T).new
  end

  def self.same_ivar(v1 : IVar(T), v2 : IVar(T)) : Bool forall T
    v1.same?(v2)
  end

  # -----------------------
  # MVar API
  # -----------------------

  def self.mvar(type : T.class) : MVar(T) forall T
    MVar(T).new
  end

  def self.mvar_init(value : T) : MVar(T) forall T
    MVar(T).new(value)
  end

  def self.same_mvar(v1 : MVar(T), v2 : MVar(T)) : Bool forall T
    v1.same?(v2)
  end

  # -----------------------
  # Channel API (additional)
  # -----------------------

  def self.same_channel(c1 : Chan(T), c2 : Chan(T)) : Bool forall T
    c1.same?(c2)
  end

  # -----------------------
  # Event API (additional)
  # -----------------------

  # Wrap an event with exception handling
  # SML: val wrapHandler : ('a event * (exn -> 'a)) -> 'a event
  def self.wrap_handler(evt : Event(T), &handler : Exception -> T) : Event(T) forall T
    WrapHandlerEvent(T).new(evt, &handler)
  end

  # Event that fires at an absolute time
  # SML: val atTimeEvt : Time.time -> unit event
  def self.at_time(target_time : Time) : Event(Nil)
    AtTimeEvent.new(target_time)
  end

  # -----------------------
  # Thread API
  # -----------------------

  # Get current thread ID
  # SML: val getTid : unit -> thread_id
  def self.get_tid : Thread::Id
    Thread::Id.current
  end

  # Compare thread IDs for equality
  # SML: val sameTid : (thread_id * thread_id) -> bool
  def self.same_tid(t1 : Thread::Id, t2 : Thread::Id) : Bool
    t1.same?(t2)
  end

  # Compare thread IDs for ordering
  # SML: val compareTid : (thread_id * thread_id) -> order
  def self.compare_tid(t1 : Thread::Id, t2 : Thread::Id) : Int32
    t1 <=> t2
  end

  # Hash a thread ID
  # SML: val hashTid : thread_id -> word
  def self.hash_tid(tid : Thread::Id) : UInt64
    tid.hash
  end

  # Convert thread ID to string
  # SML: val tidToString : thread_id -> string
  def self.tid_to_string(tid : Thread::Id) : String
    tid.to_s
  end

  # Spawn a new thread
  # SML: val spawn : (unit -> unit) -> thread_id
  def self.spawn(&block : -> Nil) : Thread::Id
    unless running?
      raise "CML is not running (call CML.run first)"
    end
    # Create a slot to hold the ThreadId reference
    tid_slot = Slot(Thread::Id).new
    fiber = ::spawn do
      begin
        block.call
      ensure
        if tid_slot.has_value?
          tid_slot.get.mark_exited
        end
      end
    end
    tid = Thread::Id.new(fiber)
    tid_slot.set(tid)
    tid
  end

  # Spawn a new thread with an argument
  # SML: val spawnc : ('a -> unit) -> 'a -> thread_id
  def self.spawnc(arg : A, &block : A -> Nil) : Thread::Id forall A
    unless running?
      raise "CML is not running (call CML.run first)"
    end
    tid_slot = Slot(Thread::Id).new
    fiber = ::spawn do
      begin
        block.call(arg)
      ensure
        if tid_slot.has_value?
          tid_slot.get.mark_exited
        end
      end
    end
    tid = Thread::Id.new(fiber)
    tid_slot.set(tid)
    tid
  end

  # Exit current thread
  # SML: val exit : unit -> 'a
  def self.exit : NoReturn
    tid = Thread::Id.for_fiber(Fiber.current)
    tid.try(&.mark_exited)
    raise Thread::Exit.new
  end

  # Event that fires when a thread exits
  # SML: val joinEvt : thread_id -> unit event
  def self.join_evt(tid : Thread::Id) : Event(Nil)
    tid.join_evt
  end

  # Yield to other threads
  # SML: val yield : unit -> unit
  def self.yield
    Fiber.yield
  end

  # -----------------------
  # Thread-Local Storage API
  # -----------------------

  # Create a new thread property with lazy initialization
  # SML: val newThreadProp : (unit -> 'a) -> {...}
  def self.new_thread_prop(type : T.class, &init : -> T) : Thread::Prop(T) forall T
    Thread::Prop(T).new(&init)
  end

  # Create a new thread flag (boolean thread-local)
  # SML: val newThreadFlag : unit -> {...}
  def self.new_thread_flag : Thread::Flag
    Thread::Flag.new
  end
end

# Optional helpers (split files to keep cml.cr smaller)
require "./cml/time_compat"
require "./cml/cleanup"
require "./cml/ivar"
require "./cml/result"
require "./cml/mvar"
require "./cml/mailbox"
require "./cml/barrier"
require "./cml/io"
require "./cml/socket"
require "./cml/socket_wrapper"
require "./cml/io_helpers"
require "./cml/stream_io"
require "./cml/imperative_io"
require "./cml/text_io"
require "./cml/bin_io"
require "./cml/process"
require "./cml/simple_rpc"
require "./cml/linda"
require "./cml/distributed_linda"
require "./cml/cvar"
require "./cml/thread"
require "./cml/multicast"
require "./cml/prim_io"
require "./cml/chan_io"
require "./cml/execution_context"
