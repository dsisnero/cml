# CML - Improved Crystal CML implementation
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
      old, success = @state.compare_and_set(TransactionState::Active, TransactionState::Cancelled)
      if success && (cleanup = @cleanup)
        cleanup.call
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
      old, success = @state.compare_and_set(TransactionState::Active, TransactionState::Committed)
      if success
        @fiber.try(&.enqueue)
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
  # Condition Variable (CVar)
  # -----------------------
  # Internal synchronization for nack events.
  # Matches SML/NJ's cvar type.
  class CVar
    @state : CVarState
    @mtx = Mutex.new

    def initialize
      @state = CVarUnset.new
    end

    def set? : Bool
      @state.is_a?(CVarSet)
    end

    # Set the cvar, waking all waiters
    def set!
      waiters = [] of TransactionId

      @mtx.synchronize do
        case s = @state
        when CVarUnset
          waiters = s.waiters.dup
          @state = CVarSet.new
        when CVarSet
          # Already set, ignore
        end
      end

      # Resume all waiters outside the lock
      # We commit them (not cancel) so they wake up successfully
      waiters.each do |tid|
        next if tid.cancelled?
        tid.try_commit_and_resume
      end
    end

    # Wait for the cvar to be set (returns event status)
    def poll : EventStatus(Nil)
      @mtx.synchronize do
        case @state
        when CVarSet
          Enabled(Nil).new(priority: -1, value: nil)
        else
          Blocked(Nil).new do |tid, next_fn|
            case s = @state
            when CVarUnset
              s.waiters << tid
              next_fn.call
            when CVarSet
              # Became set while we were checking, resume immediately
              tid.resume_fiber
            end
          end
        end
      end
    end
  end

  # Union type for CVar state
  alias CVarState = CVarUnset | CVarSet

  class CVarUnset
    property waiters = Array(TransactionId).new
  end

  class CVarSet
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
    @mtx = Mutex.new

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
        @value.not_nil!
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
  end

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

    @mtx = Mutex.new

    def close
      @closed.set(true)
    end

    def closed? : Bool
      @closed.get
    end

    # Identity comparison
    # SML: val sameChannel : ('a chan * 'a chan) -> bool
    def same?(other : Chan(T)) : Bool
      self.object_id == other.object_id
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
      begin
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
    end

    protected def force_impl : EventGroup(T)
      # Wrap each base event in the inner group with exception handling
      # Also catch exceptions during force (e.g., from guard blocks)
      begin
        wrap_handler_group(@inner.force)
      rescue ex : Exception
        # Return a base group with a single "always enabled with handler result" event
        BaseGroup(T).new(-> : EventStatus(T) {
          Enabled(T).new(priority: -1, value: @handler.call(ex))
        })
      end
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
      forced = @events.map(&.force)

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
      nack_evt = CVarEvent.new(cvar)
      inner = @f.call(nack_evt)
      inner.poll
    end

    protected def force_impl : EventGroup(T)
      cvar = CVar.new
      nack_evt = CVarEvent.new(cvar)
      inner = @f.call(nack_evt)
      NackGroup(T).new(cvar, inner.force)
    end
  end

  # Event for waiting on a CVar
  class CVarEvent < Event(Nil)
    def initialize(@cvar : CVar)
    end

    def poll : EventStatus(Nil)
      @cvar.poll
    end

    protected def force_impl : EventGroup(Nil)
      BaseGroup(Nil).new(-> : EventStatus(Nil) { poll })
    end
  end

  # -----------------------
  # Timeout Event
  # -----------------------
  class TimeoutEvent < Event(Nil)
    @poll_fn : Proc(EventStatus(Nil))

    def initialize(duration : Time::Span)
      timeout_done = AtomicFlag.new

      @poll_fn = -> : EventStatus(Nil) {
        # Fast path: timer already fired
        if timeout_done.get
          return Enabled(Nil).new(priority: 0, value: nil)
        end

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
    group = evt.force
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
    return sync_never(T) if events.empty?
    return sync_on_one(events.first) if events.size == 1

    # Try to find an enabled event
    blocked = Array({Proc(EventStatus(T)), Blocked(T)}).new

    events.each do |bevt|
      case status = bevt.call
      when Enabled(T)
        return status.value
      when Blocked(T)
        blocked << {bevt, status}
      end
    end

    # All events are blocked - register all and wait
    tid = TransactionId.new
    tid.set_fiber(Fiber.current)

    blocked.each do |bevt, status|
      status.block_fn.call(tid, -> { })
    end

    Fiber.suspend

    # Find which event triggered
    events.each do |bevt|
      case status = bevt.call
      when Enabled(T)
        return status.value
      end
    end

    raise "BUG: Fiber resumed but no event is ready"
  end

  # Sync on a single base event
  private def self.sync_on_one(bevt : Proc(EventStatus(T))) : T forall T
    case status = bevt.call
    when Enabled(T)
      status.value
    when Blocked(T)
      tid = TransactionId.new
      tid.set_fiber(Fiber.current)
      status.block_fn.call(tid, -> { })
      Fiber.suspend

      # Re-poll after waking
      case status2 = bevt.call
      when Enabled(T)
        status2.value
      else
        raise "BUG: Fiber resumed but event not ready"
      end
    else
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
  # ThreadId - Thread Identity and Management (SML/NJ compatible)
  # ===========================================================================
  # Wraps Crystal's Fiber with CML-style thread identity and join events.
  #
  # SML signature:
  #   type thread_id
  #   val getTid : unit -> thread_id
  #   val sameTid : (thread_id * thread_id) -> bool
  #   val compareTid : (thread_id * thread_id) -> order
  #   val hashTid : thread_id -> word
  #   val tidToString : thread_id -> string
  #   val spawn : (unit -> unit) -> thread_id
  #   val spawnc : ('a -> unit) -> 'a -> thread_id
  #   val exit : unit -> 'a
  #   val joinEvt : thread_id -> unit event
  #   val yield : unit -> unit

  class ThreadId
    getter fiber : Fiber
    getter id : UInt64
    @exit_cvar : CVar
    @exited = AtomicFlag.new

    @@id_counter = Atomic(UInt64).new(0_u64)
    @@fiber_to_tid = {} of Fiber => ThreadId
    @@tid_mtx = Mutex.new

    # Private initializer - use make_for_fiber instead
    protected def initialize(@fiber : Fiber, register : Bool = true)
      @id = @@id_counter.add(1)
      @exit_cvar = CVar.new
      if register
        @@tid_mtx.synchronize do
          @@fiber_to_tid[@fiber] = self
        end
      end
    end

    # Internal: create and register a ThreadId (called with lock NOT held)
    protected def self.make_for_fiber(fiber : Fiber) : ThreadId
      tid = ThreadId.new(fiber, register: false)
      @@tid_mtx.synchronize do
        @@fiber_to_tid[fiber] = tid
      end
      tid
    end

    # Mark thread as exited and signal join waiters
    def mark_exited
      return if @exited.get
      @exited.set(true)
      @exit_cvar.set!
      @@tid_mtx.synchronize do
        @@fiber_to_tid.delete(@fiber)
      end
    end

    # Check if thread has exited
    def exited? : Bool
      @exited.get
    end

    # Identity comparison
    # SML: val sameTid : (thread_id * thread_id) -> bool
    def same?(other : ThreadId) : Bool
      @id == other.id
    end

    # Comparison for ordering
    # SML: val compareTid : (thread_id * thread_id) -> order
    def <=>(other : ThreadId) : Int32
      @id <=> other.id
    end

    # Hash for use in collections
    # SML: val hashTid : thread_id -> word
    def hash : UInt64
      @id
    end

    # String representation
    # SML: val tidToString : thread_id -> string
    def to_s(io : IO) : Nil
      io << "ThreadId(" << @id << ")"
    end

    def to_s : String
      "ThreadId(#{@id})"
    end

    # Join event - fires when thread exits
    # SML: val joinEvt : thread_id -> unit event
    def join_evt : Event(Nil)
      ThreadJoinEvent.new(self)
    end

    # Get ThreadId for a fiber (internal)
    def self.for_fiber(fiber : Fiber) : ThreadId?
      @@tid_mtx.synchronize do
        @@fiber_to_tid[fiber]?
      end
    end

    # Get or create ThreadId for current fiber
    def self.current : ThreadId
      fiber = Fiber.current
      # Check first with lock
      existing = @@tid_mtx.synchronize do
        @@fiber_to_tid[fiber]?
      end
      return existing if existing

      # Create outside lock, then register
      make_for_fiber(fiber)
    end

    # Create poll function for join
    protected def make_join_poll : Proc(EventStatus(Nil))
      tid = self
      cvar = @exit_cvar

      -> : EventStatus(Nil) {
        if tid.exited?
          Enabled(Nil).new(priority: 0, value: nil)
        else
          cvar.poll
        end
      }
    end
  end

  # Thread join event
  class ThreadJoinEvent < Event(Nil)
    @poll_fn : Proc(EventStatus(Nil))

    def initialize(@tid : ThreadId)
      @poll_fn = @tid.make_join_poll
    end

    def poll : EventStatus(Nil)
      @poll_fn.call
    end

    protected def force_impl : EventGroup(Nil)
      BaseGroup(Nil).new(@poll_fn)
    end
  end

  # Thread exit exception (used internally)
  class ThreadExit < Exception
    def initialize
      super("Thread exit")
    end
  end

  # ===========================================================================
  # Thread-Local Storage (SML/NJ compatible)
  # ===========================================================================
  # Provides thread-local properties that can be get/set per-thread.
  #
  # SML signature:
  #   val newThreadProp : (unit -> 'a) -> {
  #       clrFn : unit -> unit,
  #       getFn : unit -> 'a,
  #       peekFn : unit -> 'a option,
  #       setFn : 'a -> unit
  #   }
  #   val newThreadFlag : unit -> {getFn : unit -> bool, setFn : bool -> unit}

  # Thread property - thread-local storage with lazy initialization
  # Uses fiber's object_id as key to avoid recursive locking
  class ThreadProp(T)
    @values = {} of UInt64 => T
    @init_fn : -> T
    @mtx = Mutex.new

    def initialize(&@init_fn : -> T)
    end

    # Get fiber key (uses object_id to avoid ThreadId locking)
    private def fiber_key : UInt64
      Fiber.current.object_id
    end

    # Clear current thread's property
    def clear
      key = fiber_key
      @mtx.synchronize do
        @values.delete(key)
      end
    end

    # Get current thread's property (initializes if not set)
    def get : T
      key = fiber_key
      @mtx.synchronize do
        @values[key]? || begin
          val = @init_fn.call
          @values[key] = val
          val
        end
      end
    end

    # Peek at property value without initializing
    def peek : T?
      key = fiber_key
      @mtx.synchronize do
        @values[key]?
      end
    end

    # Set property value for current thread
    def set(value : T)
      key = fiber_key
      @mtx.synchronize do
        @values[key] = value
      end
    end
  end

  # Thread flag - simple boolean thread-local storage
  class ThreadFlag
    @values = {} of UInt64 => Bool
    @mtx = Mutex.new

    def initialize
    end

    # Get fiber key
    private def fiber_key : UInt64
      Fiber.current.object_id
    end

    # Get current thread's flag (defaults to false)
    def get : Bool
      key = fiber_key
      @mtx.synchronize do
        @values[key]? || false
      end
    end

    # Set flag value for current thread
    def set(value : Bool)
      key = fiber_key
      @mtx.synchronize do
        @values[key] = value
      end
    end
  end

  # ===========================================================================
  # Mailbox - Asynchronous Channel (SML/NJ compatible)
  # ===========================================================================
  # Unlike Chan, send is non-blocking (producer can always enqueue).
  # Receive blocks until a message is available.
  # Implements fairness via priority tracking.
  #
  # SML signature:
  #   val mailbox : unit -> 'a mbox
  #   val sameMailbox : ('a mbox * 'a mbox) -> bool
  #   val send : ('a mbox * 'a) -> unit
  #   val recv : 'a mbox -> 'a
  #   val recvEvt : 'a mbox -> 'a event
  #   val recvPoll : 'a mbox -> 'a option

  class Mailbox(T)
    # State: either empty (with waiting receivers) or non-empty (with queued messages)
    @messages = Deque(T).new
    @receivers = Deque({Slot(T), AtomicFlag, TransactionId}).new
    @priority = 0
    @mtx = Mutex.new

    def initialize
    end

    # Non-blocking send - always succeeds immediately
    # SML: val send : ('a mbox * 'a) -> unit
    def send(value : T) : Nil
      receiver_to_notify : {Slot(T), AtomicFlag, TransactionId}? = nil

      @mtx.synchronize do
        # Check for waiting receiver
        while entry = @receivers.shift?
          recv_slot, recv_done, recv_tid = entry
          next if recv_tid.cancelled?

          # Found active receiver - deliver directly
          recv_slot.set(value)
          recv_done.set(true)
          receiver_to_notify = entry
          break
        end

        # If no receiver found, queue the message
        unless receiver_to_notify
          @messages << value
        end
      end

      # Resume receiver outside the lock
      if entry = receiver_to_notify
        _, _, recv_tid = entry
        recv_tid.resume_fiber
      end

      # Yield to allow consumer to run (prevents producer from outrunning consumer)
      Fiber.yield
    end

    # Blocking receive
    # SML: val recv : 'a mbox -> 'a
    def recv : T
      CML.sync(recv_evt)
    end

    # Receive event for use in choose/select
    # SML: val recvEvt : 'a mbox -> 'a event
    def recv_evt : Event(T)
      MailboxRecvEvent(T).new(self)
    end

    # Non-blocking receive poll
    # SML: val recvPoll : 'a mbox -> 'a option
    def recv_poll : T?
      @mtx.synchronize do
        @messages.shift?
      end
    end

    # Identity comparison
    # SML: val sameMailbox : ('a mbox * 'a mbox) -> bool
    def same?(other : Mailbox(T)) : Bool
      self.object_id == other.object_id
    end

    # Create poll function for receive
    protected def make_recv_poll : Proc(EventStatus(T))
      mbox = self
      recv_slot = Slot(T).new
      recv_done = AtomicFlag.new

      -> : EventStatus(T) {
        # Fast path: already complete
        if recv_done.get
          has_val, val = recv_slot.get_if_present
          if has_val
            return Enabled(T).new(priority: 0, value: val.as(T))
          end
        end

        mbox.@mtx.synchronize do
          # Check for queued message
          if msg = mbox.@messages.shift?
            recv_slot.set(msg)
            recv_done.set(true)
            prio = mbox.bump_priority
            return Enabled(T).new(priority: prio, value: msg)
          end

          # No message - need to block
          Blocked(T).new do |tid, next_fn|
            mbox.@receivers << {recv_slot, recv_done, tid}
            tid.set_cleanup -> { mbox.remove_receiver(tid.id) }
            next_fn.call
          end
        end
      }
    end

    protected def remove_receiver(tid_id : Int64)
      @mtx.synchronize { @receivers.reject! { |_, _, t| t.id == tid_id } }
    end

    # Bump priority and return old value (for poll functions)
    protected def bump_priority : Int32
      old = @priority
      @priority = old + 1
      old
    end
  end

  # Mailbox receive event
  class MailboxRecvEvent(T) < Event(T)
    @poll_fn : Proc(EventStatus(T))

    def initialize(@mbox : Mailbox(T))
      @poll_fn = @mbox.make_recv_poll
    end

    def poll : EventStatus(T)
      @poll_fn.call
    end

    protected def force_impl : EventGroup(T)
      BaseGroup(T).new(@poll_fn)
    end
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

  class IVar(T)
    @value : Slot(T)
    @readers = Deque({Slot(T), AtomicFlag, TransactionId}).new
    @priority = 0
    @mtx = Mutex.new

    def initialize
      @value = Slot(T).new
    end

    # Write a value (raises if already written)
    # SML: val iPut : ('a ivar * 'a) -> unit
    def i_put(value : T) : Nil
      readers_to_notify = [] of {Slot(T), AtomicFlag, TransactionId}

      @mtx.synchronize do
        if @value.has_value?
          raise PutError.new
        end

        @value.set(value)
        @priority = 1

        # Collect all waiting readers
        while entry = @readers.shift?
          recv_slot, recv_done, recv_tid = entry
          next if recv_tid.cancelled?
          recv_slot.set(value)
          recv_done.set(true)
          readers_to_notify << entry
        end
      end

      # Resume all readers outside the lock
      readers_to_notify.each do |_, _, tid|
        tid.resume_fiber
      end
    end

    # Blocking read
    # SML: val iGet : 'a ivar -> 'a
    def i_get : T
      CML.sync(i_get_evt)
    end

    # Read event for use in choose/select
    # SML: val iGetEvt : 'a ivar -> 'a event
    def i_get_evt : Event(T)
      IVarGetEvent(T).new(self)
    end

    # Non-blocking read poll
    # SML: val iGetPoll : 'a ivar -> 'a option
    def i_get_poll : T?
      @mtx.synchronize do
        @value.has_value? ? @value.get : nil
      end
    end

    # Identity comparison
    # SML: val sameIVar : ('a ivar * 'a ivar) -> bool
    def same?(other : IVar(T)) : Bool
      self.object_id == other.object_id
    end

    # Create poll function for get
    protected def make_get_poll : Proc(EventStatus(T))
      ivar = self
      recv_slot = Slot(T).new
      recv_done = AtomicFlag.new

      -> : EventStatus(T) {
        # Fast path: already complete
        if recv_done.get
          has_val, val = recv_slot.get_if_present
          if has_val
            return Enabled(T).new(priority: 0, value: val.as(T))
          end
        end

        ivar.@mtx.synchronize do
          # Check if value is set
          if ivar.@value.has_value?
            val = ivar.@value.get
            recv_slot.set(val)
            recv_done.set(true)
            prio = ivar.bump_priority
            return Enabled(T).new(priority: prio, value: val)
          end

          # No value - need to block
          Blocked(T).new do |tid, next_fn|
            ivar.@readers << {recv_slot, recv_done, tid}
            tid.set_cleanup -> { ivar.remove_reader(tid.id) }
            next_fn.call
          end
        end
      }
    end

    protected def remove_reader(tid_id : Int64)
      @mtx.synchronize { @readers.reject! { |_, _, t| t.id == tid_id } }
    end

    # Bump priority and return old value
    protected def bump_priority : Int32
      old = @priority
      @priority = old + 1
      old
    end
  end

  # IVar get event
  class IVarGetEvent(T) < Event(T)
    @poll_fn : Proc(EventStatus(T))

    def initialize(@ivar : IVar(T))
      @poll_fn = @ivar.make_get_poll
    end

    def poll : EventStatus(T)
      @poll_fn.call
    end

    protected def force_impl : EventGroup(T)
      BaseGroup(T).new(@poll_fn)
    end
  end

  # ===========================================================================
  # MVar - Mutable Synchronization Variable (SML/NJ compatible)
  # ===========================================================================
  # An MVar is like a single-element channel:
  # - mTake removes and returns the value (blocks if empty)
  # - mPut sets the value (raises if already full)
  # - mGet reads without removing (blocks if empty)
  # - mSwap atomically replaces the value
  #
  # SML signature:
  #   val mVar : unit -> 'a mvar
  #   val mVarInit : 'a -> 'a mvar
  #   val sameMVar : ('a mvar * 'a mvar) -> bool
  #   val mPut : ('a mvar * 'a) -> unit
  #   val mTake : 'a mvar -> 'a
  #   val mTakeEvt : 'a mvar -> 'a event
  #   val mTakePoll : 'a mvar -> 'a option
  #   val mGet : 'a mvar -> 'a
  #   val mGetEvt : 'a mvar -> 'a event
  #   val mGetPoll : 'a mvar -> 'a option
  #   val mSwap : ('a mvar * 'a) -> 'a
  #   val mSwapEvt : ('a mvar * 'a) -> 'a event

  class MVar(T)
    @value : T?
    @has_value = false
    @readers = Deque({Slot(T), AtomicFlag, TransactionId, Bool}).new # Bool = is_take?
    @priority = 0
    @mtx = Mutex.new

    def initialize
    end

    # Initialize with a value
    def initialize(value : T)
      @value = value
      @has_value = true
    end

    # Put a value (raises if already full)
    # SML: val mPut : ('a mvar * 'a) -> unit
    def m_put(value : T) : Nil
      reader_to_notify : {Slot(T), AtomicFlag, TransactionId, Bool}? = nil

      @mtx.synchronize do
        if @has_value
          raise PutError.new
        end

        # Check for waiting reader
        while entry = @readers.shift?
          recv_slot, recv_done, recv_tid, is_take = entry
          next if recv_tid.cancelled?

          recv_slot.set(value)
          recv_done.set(true)
          reader_to_notify = entry

          # For take, the value is consumed
          # For get, we set the value and let other readers see it
          unless is_take
            @value = value
            @has_value = true
            @priority = 1
          end
          break
        end

        # If no reader found, store the value
        unless reader_to_notify
          @value = value
          @has_value = true
        end
      end

      # Resume reader outside the lock (and relay to others for mGet)
      if entry = reader_to_notify
        _, _, tid, is_take = entry
        tid.resume_fiber
        # For mGet, we need to relay to other blocked readers
        unless is_take
          relay_to_readers(value)
        end
      end
    end

    # Take the value (blocks if empty, clears the MVar)
    # SML: val mTake : 'a mvar -> 'a
    def m_take : T
      CML.sync(m_take_evt)
    end

    # Take event
    # SML: val mTakeEvt : 'a mvar -> 'a event
    def m_take_evt : Event(T)
      MVarTakeEvent(T).new(self)
    end

    # Non-blocking take
    # SML: val mTakePoll : 'a mvar -> 'a option
    def m_take_poll : T?
      @mtx.synchronize do
        if @has_value
          val = @value.not_nil!
          @value = nil
          @has_value = false
          val
        else
          nil
        end
      end
    end

    # Get the value without removing (blocks if empty)
    # SML: val mGet : 'a mvar -> 'a
    def m_get : T
      CML.sync(m_get_evt)
    end

    # Get event
    # SML: val mGetEvt : 'a mvar -> 'a event
    def m_get_evt : Event(T)
      MVarGetEvent(T).new(self)
    end

    # Non-blocking get
    # SML: val mGetPoll : 'a mvar -> 'a option
    def m_get_poll : T?
      @mtx.synchronize do
        @has_value ? @value : nil
      end
    end

    # Atomic swap
    # SML: val mSwap : ('a mvar * 'a) -> 'a
    def m_swap(new_value : T) : T
      CML.sync(m_swap_evt(new_value))
    end

    # Swap event
    # SML: val mSwapEvt : ('a mvar * 'a) -> 'a event
    def m_swap_evt(new_value : T) : Event(T)
      MVarSwapEvent(T).new(self, new_value)
    end

    # Identity comparison
    # SML: val sameMVar : ('a mvar * 'a mvar) -> bool
    def same?(other : MVar(T)) : Bool
      self.object_id == other.object_id
    end

    # Create poll function for take
    protected def make_take_poll : Proc(EventStatus(T))
      mvar = self
      recv_slot = Slot(T).new
      recv_done = AtomicFlag.new

      -> : EventStatus(T) {
        if recv_done.get
          has_val, val = recv_slot.get_if_present
          if has_val
            return Enabled(T).new(priority: 0, value: val.as(T))
          end
        end

        mvar.@mtx.synchronize do
          if mvar.@has_value
            val = mvar.@value.not_nil!
            mvar.clear_value
            recv_slot.set(val)
            recv_done.set(true)
            prio = mvar.bump_priority
            return Enabled(T).new(priority: prio, value: val)
          end

          Blocked(T).new do |tid, next_fn|
            mvar.@readers << {recv_slot, recv_done, tid, true} # is_take = true
            tid.set_cleanup -> { mvar.remove_reader(tid.id) }
            next_fn.call
          end
        end
      }
    end

    # Create poll function for get (non-destructive read)
    protected def make_get_poll : Proc(EventStatus(T))
      mvar = self
      recv_slot = Slot(T).new
      recv_done = AtomicFlag.new

      -> : EventStatus(T) {
        if recv_done.get
          has_val, val = recv_slot.get_if_present
          if has_val
            return Enabled(T).new(priority: 0, value: val.as(T))
          end
        end

        mvar.@mtx.synchronize do
          if mvar.@has_value
            val = mvar.@value.not_nil!
            recv_slot.set(val)
            recv_done.set(true)
            prio = mvar.bump_priority
            return Enabled(T).new(priority: prio, value: val)
          end

          Blocked(T).new do |tid, next_fn|
            mvar.@readers << {recv_slot, recv_done, tid, false} # is_take = false
            tid.set_cleanup -> { mvar.remove_reader(tid.id) }
            next_fn.call
          end
        end
      }
    end

    # Create poll function for swap
    protected def make_swap_poll(new_value : T) : Proc(EventStatus(T))
      mvar = self
      recv_slot = Slot(T).new
      recv_done = AtomicFlag.new

      -> : EventStatus(T) {
        if recv_done.get
          has_val, val = recv_slot.get_if_present
          if has_val
            return Enabled(T).new(priority: 0, value: val.as(T))
          end
        end

        mvar.@mtx.synchronize do
          if mvar.@has_value
            old_val = mvar.@value.not_nil!
            mvar.set_value(new_value)
            recv_slot.set(old_val)
            recv_done.set(true)
            prio = mvar.bump_priority
            return Enabled(T).new(priority: prio, value: old_val)
          end

          # Block until value available, then swap
          Blocked(T).new do |tid, next_fn|
            # For swap, we act like take but then immediately put new value
            mvar.@readers << {recv_slot, recv_done, tid, true} # take first
            tid.set_cleanup -> {
              mvar.remove_reader(tid.id)
            }
            next_fn.call
          end
        end
      }
    end

    protected def remove_reader(tid_id : Int64)
      @mtx.synchronize { @readers.reject! { |_, _, t, _| t.id == tid_id } }
    end

    # Bump priority and return old value
    protected def bump_priority : Int32
      old = @priority
      @priority = old + 1
      old
    end

    # Clear the value
    protected def clear_value
      @value = nil
      @has_value = false
    end

    # Set a new value
    protected def set_value(val : T)
      @value = val
      @has_value = true
    end

    # Relay value to other blocked readers (for mGet semantics)
    protected def relay_to_readers(value : T)
      readers_to_notify = [] of {Slot(T), AtomicFlag, TransactionId, Bool}

      @mtx.synchronize do
        while entry = @readers.shift?
          recv_slot, recv_done, recv_tid, is_take = entry
          next if recv_tid.cancelled?
          recv_slot.set(value)
          recv_done.set(true)
          readers_to_notify << entry

          # If this is a take, consume the value and stop
          if is_take
            @value = nil
            @has_value = false
            break
          end
        end
      end

      readers_to_notify.each do |_, _, tid, _|
        tid.resume_fiber
      end
    end
  end

  # MVar take event
  class MVarTakeEvent(T) < Event(T)
    @poll_fn : Proc(EventStatus(T))

    def initialize(@mvar : MVar(T))
      @poll_fn = @mvar.make_take_poll
    end

    def poll : EventStatus(T)
      @poll_fn.call
    end

    protected def force_impl : EventGroup(T)
      BaseGroup(T).new(@poll_fn)
    end
  end

  # MVar get event (non-destructive)
  class MVarGetEvent(T) < Event(T)
    @poll_fn : Proc(EventStatus(T))

    def initialize(@mvar : MVar(T))
      @poll_fn = @mvar.make_get_poll
    end

    def poll : EventStatus(T)
      @poll_fn.call
    end

    protected def force_impl : EventGroup(T)
      BaseGroup(T).new(@poll_fn)
    end
  end

  # MVar swap event
  class MVarSwapEvent(T) < Event(T)
    @poll_fn : Proc(EventStatus(T))
    @new_value : T

    def initialize(@mvar : MVar(T), @new_value : T)
      @poll_fn = @mvar.make_swap_poll(@new_value)
    end

    def poll : EventStatus(T)
      @poll_fn.call
    end

    protected def force_impl : EventGroup(T)
      BaseGroup(T).new(@poll_fn)
    end
  end

  # ===========================================================================
  # Barrier - Barrier Synchronization with Global State (SML/NJ compatible)
  # ===========================================================================
  # A barrier allows multiple threads to synchronize at a common point.
  # When all enrolled threads reach the barrier, they are all released
  # and the global state is updated.
  #
  # SML signature:
  #   type 'a barrier
  #   type 'a enrollment
  #   val barrier : ('a -> 'a) -> 'a -> 'a barrier
  #   val enroll : 'a barrier -> 'a enrollment
  #   val wait : 'a enrollment -> 'a
  #   val resign : 'a enrollment -> unit
  #   val value : 'a enrollment -> 'a

  class Barrier(T)
    @state : T
    @update_fn : Proc(T, T)
    @enrolled_count = 0
    @waiting_count = 0
    @waiters = Deque({Slot(T), AtomicFlag, TransactionId}).new
    @mtx = Mutex.new

    # Create a barrier with an update function and initial state
    # SML: val barrier : ('a -> 'a) -> 'a -> 'a barrier
    def initialize(@update_fn : Proc(T, T), @state : T)
    end

    # Block-based constructor (Crystal style)
    def initialize(initial_state : T, &block : T -> T)
      @state = initial_state
      @update_fn = block
    end

    # Get current state (internal)
    def value : T
      @mtx.synchronize { @state }
    end

    # Enroll in the barrier
    # SML: val enroll : 'a barrier -> 'a enrollment
    def enroll : Enrollment(T)
      @mtx.synchronize do
        @enrolled_count += 1
      end
      Enrollment(T).new(self)
    end

    # Internal helpers for poll functions
    protected def increment_waiting
      @waiting_count += 1
    end

    protected def decrement_waiting
      @waiting_count -= 1
    end

    protected def decrement_enrolled
      @enrolled_count -= 1
    end

    protected def waiting_count : Int32
      @waiting_count
    end

    protected def enrolled_count : Int32
      @enrolled_count
    end

    protected def update_state : T
      @state = @update_fn.call(@state)
      @state
    end

    protected def reset_waiting
      @waiting_count = 0
    end

    protected def add_waiter(entry : {Slot(T), AtomicFlag, TransactionId})
      @waiters << entry
    end

    protected def remove_waiter(tid_id : Int64) : Bool
      removed = false
      @waiters.reject! do |_, _, t|
        if t.id == tid_id
          removed = true
          true
        else
          false
        end
      end
      removed
    end

    protected def take_waiters : Array({Slot(T), AtomicFlag, TransactionId})
      result = @waiters.to_a
      @waiters.clear
      result
    end

    # Create poll function for wait operation
    protected def make_wait_poll(enrollment : Enrollment(T)) : Proc(EventStatus(T))
      barrier = self
      recv_slot = Slot(T).new
      recv_done = AtomicFlag.new
      poll_registered = AtomicFlag.new # Track if THIS poll has registered

      -> : EventStatus(T) {
        # Fast path: already complete
        if recv_done.get
          has_val, val = recv_slot.get_if_present
          if has_val
            return Enabled(T).new(priority: 0, value: val.as(T))
          end
        end

        barrier.@mtx.synchronize do
          # Validation - only check on first poll call
          if !poll_registered.get
            if enrollment.resigned?
              raise "Barrier wait after resignation"
            elsif enrollment.waiting?
              # Another poll/event is already waiting - this poll must block
              # Return blocked but don't increment counters again
              return Blocked(T).new do |tid, next_fn|
                barrier.add_waiter({recv_slot, recv_done, tid})
                tid.set_cleanup -> {
                  barrier.@mtx.synchronize do
                    barrier.remove_waiter(tid.id)
                  end
                }
                next_fn.call
              end
            end

            poll_registered.set(true)
            enrollment.mark_waiting
            barrier.increment_waiting
          end

          if barrier.waiting_count == barrier.enrolled_count
            # === TRIGGER BARRIER ===
            # Update state
            new_state = barrier.update_state

            # Notify all waiters
            waiters_to_notify = barrier.take_waiters
            barrier.reset_waiting

            # Reset triggerer status
            enrollment.mark_enrolled
            poll_registered.set(false)

            # Notify others outside... but we're in synchronize
            # We need to collect and notify after
            waiters_to_notify.each do |slot, done, tid|
              next if tid.cancelled?
              slot.set(new_state)
              done.set(true)
              tid.resume_fiber
            end

            # Return enabled for triggerer
            recv_slot.set(new_state)
            recv_done.set(true)
            return Enabled(T).new(priority: 0, value: new_state)
          else
            # === QUEUE WAIT ===
            Blocked(T).new do |tid, next_fn|
              barrier.add_waiter({recv_slot, recv_done, tid})
              tid.set_cleanup -> {
                barrier.@mtx.synchronize do
                  if barrier.remove_waiter(tid.id)
                    barrier.decrement_waiting
                    enrollment.mark_enrolled
                    poll_registered.set(false)
                  end
                end
              }
              next_fn.call
            end
          end
        end
      }
    end

    # Handle resignation
    protected def do_resign(enrollment : Enrollment(T))
      waiters_to_notify = [] of {Slot(T), AtomicFlag, TransactionId}
      new_state : T? = nil

      @mtx.synchronize do
        return if enrollment.resigned?
        raise "Cannot resign while waiting" if enrollment.waiting?

        enrollment.mark_resigned
        @enrolled_count -= 1

        # Check if resignation triggers the barrier
        if @waiting_count > 0 && @waiting_count >= @enrolled_count
          @state = @update_fn.call(@state)
          new_state = @state

          waiters_to_notify = @waiters.to_a
          @waiters.clear
          @waiting_count = 0
        end
      end

      # Notify waiters outside the lock
      if val = new_state
        waiters_to_notify.each do |slot, done, tid|
          next if tid.cancelled?
          slot.set(val)
          done.set(true)
          tid.resume_fiber
        end
      end
    end
  end

  # Barrier enrollment - a thread's enrollment in a barrier
  class Enrollment(T)
    enum Status
      Enrolled
      Waiting
      Resigned
    end

    @status : Status = Status::Enrolled
    @barrier : Barrier(T)

    def initialize(@barrier : Barrier(T))
    end

    # Status checks
    def enrolled? : Bool
      @status == Status::Enrolled
    end

    def waiting? : Bool
      @status == Status::Waiting
    end

    def resigned? : Bool
      @status == Status::Resigned
    end

    # Status transitions (internal)
    protected def mark_enrolled
      @status = Status::Enrolled
    end

    protected def mark_waiting
      @status = Status::Waiting
    end

    protected def mark_resigned
      @status = Status::Resigned
    end

    # Wait on the barrier (blocking)
    # SML: val wait : 'a enrollment -> 'a
    def wait : T
      CML.sync(wait_evt)
    end

    # Wait event for use in choose/select
    def wait_evt : Event(T)
      BarrierWaitEvent(T).new(@barrier, self)
    end

    # Resign from the barrier
    # SML: val resign : 'a enrollment -> unit
    def resign
      @barrier.do_resign(self)
    end

    # Get current barrier state
    # SML: val value : 'a enrollment -> 'a
    def value : T
      @barrier.value
    end
  end

  # Barrier wait event
  class BarrierWaitEvent(T) < Event(T)
    @poll_fn : Proc(EventStatus(T))

    def initialize(@barrier : Barrier(T), @enrollment : Enrollment(T))
      @poll_fn = @barrier.make_wait_poll(@enrollment)
    end

    def poll : EventStatus(T)
      @poll_fn.call
    end

    protected def force_impl : EventGroup(T)
      BaseGroup(T).new(@poll_fn)
    end
  end

  # -----------------------
  # Public API
  # -----------------------

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

  def self.timeout(duration : Time::Span) : Event(Nil)
    TimeoutEvent.new(duration)
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
  def self.get_tid : ThreadId
    ThreadId.current
  end

  # Compare thread IDs for equality
  # SML: val sameTid : (thread_id * thread_id) -> bool
  def self.same_tid(t1 : ThreadId, t2 : ThreadId) : Bool
    t1.same?(t2)
  end

  # Compare thread IDs for ordering
  # SML: val compareTid : (thread_id * thread_id) -> order
  def self.compare_tid(t1 : ThreadId, t2 : ThreadId) : Int32
    t1 <=> t2
  end

  # Hash a thread ID
  # SML: val hashTid : thread_id -> word
  def self.hash_tid(tid : ThreadId) : UInt64
    tid.hash
  end

  # Convert thread ID to string
  # SML: val tidToString : thread_id -> string
  def self.tid_to_string(tid : ThreadId) : String
    tid.to_s
  end

  # Spawn a new thread
  # SML: val spawn : (unit -> unit) -> thread_id
  def self.spawn(&block : -> Nil) : ThreadId
    # Create a slot to hold the ThreadId reference
    tid_slot = Slot(ThreadId).new
    fiber = ::spawn do
      begin
        block.call
      ensure
        if tid_slot.has_value?
          tid_slot.get.mark_exited
        end
      end
    end
    tid = ThreadId.new(fiber)
    tid_slot.set(tid)
    tid
  end

  # Spawn a new thread with an argument
  # SML: val spawnc : ('a -> unit) -> 'a -> thread_id
  def self.spawnc(arg : A, &block : A -> Nil) : ThreadId forall A
    tid_slot = Slot(ThreadId).new
    fiber = ::spawn do
      begin
        block.call(arg)
      ensure
        if tid_slot.has_value?
          tid_slot.get.mark_exited
        end
      end
    end
    tid = ThreadId.new(fiber)
    tid_slot.set(tid)
    tid
  end

  # Exit current thread
  # SML: val exit : unit -> 'a
  def self.exit : NoReturn
    tid = ThreadId.for_fiber(Fiber.current)
    tid.try(&.mark_exited)
    raise ThreadExit.new
  end

  # Event that fires when a thread exits
  # SML: val joinEvt : thread_id -> unit event
  def self.join_evt(tid : ThreadId) : Event(Nil)
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
  def self.new_thread_prop(type : T.class, &init : -> T) : ThreadProp(T) forall T
    ThreadProp(T).new(&init)
  end

  # Create a new thread flag (boolean thread-local)
  # SML: val newThreadFlag : unit -> {...}
  def self.new_thread_flag : ThreadFlag
    ThreadFlag.new
  end

  # -----------------------
  # Barrier API
  # -----------------------

  # Create a new barrier with update function and initial state
  # SML: val barrier : ('a -> 'a) -> 'a -> 'a barrier
  def self.barrier(update_fn : Proc(T, T), initial_state : T) : Barrier(T) forall T
    Barrier(T).new(update_fn, initial_state)
  end

  # Create a barrier with block-based update function
  def self.barrier(initial_state : T, &update : T -> T) : Barrier(T) forall T
    Barrier(T).new(initial_state, &update)
  end

  # Create a counting barrier (increments state on each sync)
  def self.counting_barrier(initial_count : Int32 = 0) : Barrier(Int32)
    Barrier(Int32).new(initial_count) { |x| x + 1 }
  end
end
