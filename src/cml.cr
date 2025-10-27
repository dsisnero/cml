# src/cml.cr
# Concurrent ML runtime in Crystal
# Supports: Event, sync, choose, wrap, guard, nack, timeout, channels with cancellation

module CML
  # Global timer wheel instance for efficient timeout management.
  # The timer wheel automatically starts its own processing fiber.
  class_getter timer_wheel : TimerWheel = TimerWheel.new

  # -----------------------
  # Commit Cell (Pick)
  # -----------------------
  # A commit cell that represents a choice decision.
  # Used internally by the CML runtime to manage event synchronization.
  #
  # @type T The type of value this pick can decide
  class Pick(T)
    @winner : T? = nil
    @done = Channel(Nil).new(1)
    @decided = Atomic(Bool).new(false)
    @cancellations = [] of Proc(Nil)
    @mtx = Mutex.new

    def add_cancel(proc : Proc(Nil))
      @mtx.synchronize { @cancellations << proc }
    end

    # Attempts to decide this pick with the given value.
    # Only succeeds if the pick hasn't been decided yet.
    # This operation is atomic and thread-safe.
    def try_decide(value : T) : Bool
      # Fast path check without lock
      return false if decided?

      cancellations_to_run = [] of Proc(Nil)
      made_decision = false

      @mtx.synchronize do
        if @decided.compare_and_set(false, true)
          @winner = value
          @done.send(nil) rescue nil
          cancellations_to_run = @cancellations
          @cancellations = [] of Proc(Nil) # Clear to prevent re-entry
          made_decision = true
        end
      end

      # Run cancellations outside the lock. This is the key to avoiding
      # the re-entrant lock deadlocks seen in previous attempts.
      if made_decision
        cancellations_to_run.each &.call
      end

      made_decision
    end

    # Checks if this pick has been decided.
    def decided? : Bool
      @decided.get
    end

    # Gets the decided value of this pick.
    # Raises an exception if the pick hasn't been decided yet.
    def value : T
      {% if T == Nil %}
        nil
      {% else %}
        @winner.not_nil!
      {% end %}
    end

    # Waits for this pick to be decided.
    # Returns immediately if already decided.
    def wait : Nil
      return if decided?
      @done.receive
    end
  end

  # -----------------------
  # Event abstraction
  # -----------------------
  # Abstract base class for all CML events.
  # Events represent computations that may produce a value when synchronized.
  #
  # @type T The type of value this event produces
  # @abstract
  abstract class Event(T)
    # Attempts to register this event with a pick (decision point).
    # Returns a cancellation procedure that should be called if the event is no longer needed.
    abstract def try_register(pick : Pick(T)) : Proc(Nil)

    # A polling mechanism for `choose` to check for an immediate result
    # without the overhead of a full registration.
    # The default is to return nil, indicating no immediate value.
    # `AlwaysEvt` will override this.
    def poll : T?
      nil
    end
  end

  # -----------------------
  # Basic events
  # -----------------------
  # An event that always succeeds immediately with a fixed value.
  class AlwaysEvt(T) < Event(T)
    def initialize(@value : T); end

    # Immediately decides the pick with the stored value.
    # Returns an empty cancellation procedure since the decision is immediate.
    def try_register(pick : Pick(T)) : Proc(Nil)
      pick.try_decide(@value)
      -> { }
    end

    # Overrides the base `poll` to return the event's value immediately.
    # This allows `ChooseEvt` to quickly find a winner without registration.
    def poll : T?
      @value
    end
  end

  # An event that never succeeds.
  # This is useful for creating events that should never complete,
  # such as in timeout scenarios or as placeholders.
  class NeverEvt(T) < Event(T)
    # Registers with a pick but never decides it.
    # Returns an empty cancellation procedure.
    def try_register(pick : Pick(T)) : Proc(Nil)
      -> { }
    end
  end

  # -----------------------
  # Channels
  # -----------------------
  # A channel for communicating values between concurrent processes.
  # Channels support both send and receive operations as events.
  #
  # @type T The type of values communicated through this channel
  class Chan(T)
    @send_q = Deque({T, Pick(Nil)}).new
    @recv_q = Deque(Pick(T)).new
    @mtx = Mutex.new

    # Creates a send event for the given value.
    # The event completes when the value is successfully sent.
    def send_evt(value : T) : Event(Nil)
      SendEvt.new(self, value)
    end

    # Creates a receive event.
    # The event completes when a value is received from the channel.
    def recv_evt : Event(T)
      RecvEvt.new(self)
    end

    # Registers a send operation with the channel.
    # If a receiver is waiting, the value is immediately delivered.
    # Otherwise, the send is queued until a receiver arrives.
    def register_send(value : T, pick : Pick(Nil)) : Proc(Nil)
      offer = {value, pick}
      
      # Defer decision-making to outside the lock
      recv_pick_to_decide : Pick(T)? = nil

      @mtx.synchronize do
        if recv_pick = @recv_q.shift?
          # Found a waiting receiver, prepare to complete the rendezvous
          recv_pick_to_decide = recv_pick
        else
          # No receiver waiting, so add to the send queue
          @send_q << offer
        end
      end

      # Perform the decision *after* releasing the lock
      if recv_pick = recv_pick_to_decide
        recv_pick.try_decide(value)
        pick.try_decide(nil)
        return ->{} # Rendezvous complete, no-op cancel
      end

      # Return a cancellation proc that removes from the send queue
      -> { @mtx.synchronize { @send_q.delete(offer) rescue nil } }
    end

    # Registers a receive operation with the channel.
    # If a sender is waiting, the value is immediately received.
    # Otherwise, the receive is queued until a sender arrives.
    def register_recv(pick : Pick(T)) : Proc(Nil)
      offer = pick
      
      # Defer decision-making to outside the lock
      send_pair_to_decide : {T, Pick(Nil)}? = nil

      @mtx.synchronize do
        if pair = @send_q.shift?
          # Found a waiting sender, prepare to complete the rendezvous
          send_pair_to_decide = pair
        else
          # No sender waiting, so add to the receive queue
          @recv_q << offer
        end
      end

      # Perform the decision *after* releasing the lock
      if pair = send_pair_to_decide
        value, send_pick = pair
        send_pick.try_decide(nil)
        pick.try_decide(value)
        return ->{} # Rendezvous complete, no-op cancel
      end

      # Return a cancellation proc that removes from the receive queue
      -> { @mtx.synchronize { @recv_q.delete(offer) rescue nil } }
    end
  end

  # An event representing a send operation on a channel.
  # Completes when the value is successfully sent.
  class SendEvt(T) < Event(Nil)
    def initialize(@ch : Chan(T), @val : T); end

    # Registers this send event with a pick.
    def try_register(pick : Pick(Nil)) : Proc(Nil)
      @ch.register_send(@val, pick)
    end
  end

  # An event representing a receive operation on a channel.
  # Completes when a value is successfully received.
  class RecvEvt(T) < Event(T)
    def initialize(@ch : Chan(T)); end

    # Registers this receive event with a pick.
    def try_register(pick : Pick(T)) : Proc(Nil)
      @ch.register_recv(pick)
    end
  end

  # -----------------------
  # Timeout (yields :timeout)
  # -----------------------
  # An event that completes after a specified duration with the symbol `:timeout`.
  # Useful for creating time-limited operations in conjunction with `choose`.
  class TimeoutEvt < Event(Symbol)
    # Creates a new timeout event.
    def initialize(@duration : Time::Span); end

    # Registers this timeout event with a pick.
    # Uses the global timer wheel instead of spawning fibers for efficiency.
    def try_register(pick : Pick(Symbol)) : Proc(Nil)
      # Use the global timer wheel instead of spawning fibers
      timer_event = TimerEvent.new(CML.timer_wheel, @duration)
      timer_event.try_register(pick)
    end
  end

  # -----------------------
  # Wrap (post-commit transform)
  # -----------------------
  # An event that transforms the result of another event.
  # The transformation function is applied after the inner event completes.
  #
  # @type A The result type of the inner event
  # @type B The result type after transformation
  class WrapEvt(A, B) < Event(B)
    def initialize(@inner : Event(A), &@f : A -> B); end

    # Registers this wrap event with a pick.
    # Registers the inner event and applies the transformation
    # when the inner event completes.
    def try_register(pick : Pick(B)) : Proc(Nil)
      inner_pick = Pick(A).new
      cancel_inner = @inner.try_register(inner_pick)
      spawn do
        inner_pick.wait
        if inner_pick.decided?
          pick.try_decide(@f.call(inner_pick.value))
        end
      end
      cancel_inner
    end

    # A `WrapEvt` can be polled if its inner event can be.
    # This allows `choose` to see through the wrapper to an `AlwaysEvt`.
    def poll : B?
      if inner_val = @inner.poll
        @f.call(inner_val)
      end
    end
  end

  # -----------------------
  # Guard (defer creation until sync)
  # -----------------------
  # An event that defers creation of its inner event until synchronization time.
  # Useful for creating events that depend on runtime state.
  #
  # @type T The result type of the guarded event
  class GuardEvt(T) < Event(T)
    @block : Proc(Event(T))

    # Creates a new guard event.
    def initialize(&block : -> E) forall E
      @block = -> { block.call.as(Event(T)) }
    end

    # Registers this guard event with a pick.
    # Creates the inner event and registers it with the pick.
    def try_register(pick : Pick(T)) : Proc(Nil)
      evt = @block.call
      evt.try_register(pick)
    end

    # When a `GuardEvt` is polled, it must execute its block to get the
    # real event, and then poll that event. This ensures the guard's
    # side-effects are triggered correctly during the polling phase.
    def poll : T?
      @block.call.poll
    end
  end

  # -----------------------
  # Nack (run on cancel)
  # -----------------------
  # An event that runs a callback when it loses in a choice.
  # The callback is executed only if this event is registered but not chosen.
  #
    # @type T The result type of the inner event
  class NackEvt(T) < Event(T)
    # Creates a new nack event.
    def initialize(@inner : Event(T), &@on_cancel : -> Nil); end

    # Registers this nack event with a pick.
    # Wraps the inner event to track whether it wins,
    # and runs the callback if it loses.
    def try_register(pick : Pick(T)) : Proc(Nil)
      won = Atomic(Bool).new(false)

      # If this branch wins, we set won=true via a tiny wrap.
      wrapped = WrapEvt(T, T).new(@inner) { |x| won.set(true); x }

      cancel_inner = wrapped.try_register(pick)

      # IMPORTANT: tie cleanup to the cancel closure,
      # which ChooseEvt will call after the race is decided.
      -> {
        unless won.get
          @on_cancel.call
        end
        cancel_inner.call
      }
    end
  end

  # -----------------------
  # Choose
  # -----------------------
  # An event that represents a choice between multiple events.
  # The first event to complete wins and decides the pick.
  # All other events are cancelled.
  class ChooseEvt(T) < Event(T)
    getter evts : Array(Event(T))

    # Accept arrays of Event or any Event subtype (e.g., Array(RecvEvt(T))).
    def initialize(evts : Array(E)) forall E
      @evts = evts.map(&.as(Event(T)))
    end

    # Registers all events in the choice with the pick.
    # The first event to complete decides the pick,
    # and all other events are cancelled.
    def try_register(pick : Pick(T)) : Proc(Nil)
      # --- Polling Optimization ---
      @evts.each do |evt|
        if value = evt.poll
          if pick.try_decide(value)
            return ->{} # Immediate win, no cancellation needed.
          end
        end
      end

      # --- Asynchronous Registration ---
      # Register all child events and add their cancellation procs
      # directly to the pick. This avoids allocating a `cancels` array
      # and spawning a cleanup fiber.
      @evts.each do |evt|
        pick.add_cancel(evt.try_register(pick))
      end

      # The cancellation proc for the ChooseEvt itself is a no-op.
      # The pick handles cleanup of child events. This is needed
      # for nested choose scenarios where a parent choose cancels this one.
      -> { }
    end
  end

  # -----------------------
  # Future primitives (stubs)
  # -----------------------
  # These are placeholders so specs can compile while the primitives are pending.
  # They raise at registration time if accidentally used.
  class NotImplementedEvt(T) < Event(T)
    def initialize(@feature : String); end

    def try_register(pick : Pick(T)) : Proc(Nil)
      raise "Not implemented: #{@feature}"
    end
  end

  # -----------------------
  # Timer Wheel Events
  # -----------------------
    # Timer event that uses the TimerWheel for efficient timeout management
  class TimerEvent < Event(Symbol)
    @timer_id : UInt64?
    @pick : Pick(Symbol)?

    def initialize(@timer_wheel : TimerWheel, @duration : Time::Span); end

    def try_register(pick : Pick(Symbol)) : Proc(Nil)
      @pick = pick
      # Schedule the timer with the wheel
      @timer_id = @timer_wheel.schedule(@duration) do
        # The pick might be nil if cancelled immediately
        @pick.try &.try_decide(:timeout)
      end

      # Return cancellation proc
      -> {
        # Prevent the timer from firing by clearing the pick
        @pick = nil
        if timer_id = @timer_id
          @timer_wheel.cancel(timer_id)
        end
      }
    end
  end    # Interval timer event for recurring timeouts
  class IntervalTimerEvent < Event(Symbol)
    @timer_id : UInt64?
    @pick : Pick(Symbol)?

    def initialize(@timer_wheel : TimerWheel, @interval : Time::Span); end

    def try_register(pick : Pick(Symbol)) : Proc(Nil)
      @pick = pick
      # Schedule the interval timer with the wheel
      @timer_id = @timer_wheel.schedule_interval(@interval) do
        @pick.try &.try_decide(:timeout)
      end

      # Return cancellation proc
      -> {
        @pick = nil
        if timer_id = @timer_id
          @timer_wheel.cancel(timer_id)
        end
      }
    end
  end

  # -----------------------
  # Public API
  # -----------------------
  # Synchronizes on an event, waiting for it to complete and returning its result.
  # This is the core operation of CML - it blocks until the event produces a value.
  def self.sync(evt : Event(T)) : T forall T
    pick = Pick(T).new
    cancel = evt.try_register(pick)
    pick.wait
    # After waiting, if the event was a `choose`, the winner has already
    # executed the necessary cancellations via `pick.try_decide`.
    # We must still call the top-level `cancel` proc, however, for two reasons:
    # 1. The event might not have been a `choose` and needs its own cleanup.
    # 2. The event could be a nested `choose`, and this call propagates
    #    the cancellation signal upwards.
    cancel.call
    pick.value
  end

  # Creates an event that always succeeds immediately with the given value.
  def self.always(x : T) : Event(T) forall T
    AlwaysEvt(T).new(x)
  end

  # Creates an event that never succeeds.
  # Useful for creating events that should never complete,
  # such as in timeout scenarios or as placeholders.
  def self.never(type : T.class) : Event(T) forall T
    NeverEvt(T).new
  end

  # Backward-compatible Nil-typed variant.
  def self.never : Event(Nil)
    NeverEvt(Nil).new
  end

  # Creates a timeout event that completes after the specified duration.
  # The event yields the symbol `:timeout` when it completes.
  def self.timeout(duration : Time::Span) : Event(Symbol)
    TimeoutEvt.new(duration)
  end

  # Creates an event that transforms the result of another event.
  # The transformation is applied after the inner event completes.
  def self.wrap(evt : Event(A), &block : A -> B) : Event(B) forall A, B
    WrapEvt(A, B).new(evt, &block)
  end

  # Creates an event that defers creation of its inner event until synchronization time.
  # Useful for creating events that depend on runtime state.
  def self.guard(&block : -> Event(T)) : Event(T) forall T
    GuardEvt(T).new(&block)
  end

  # Creates an event that runs a callback when it loses in a choice.
  # The callback is executed only if this event is registered but not chosen.
  def self.nack(evt : Event(T), &block : -> Nil) : Event(T) forall T
    NackEvt(T).new(evt, &block)
  end

  # Creates a choice event from an array of events.
  # Note: We intentionally keep this generic (Event(T)).
  # Crystal infers T from the arguments; returning a non-generic Event
  # would break sync(evt : Event(T)) which relies on T for the result type.
  def self.choose(evts : Array(Event(T))) : Event(T) forall T
    flat = evts.flat_map { |e| e.is_a?(ChooseEvt(T)) ? e.evts : [e] }
    ChooseEvt(T).new(flat)
  end

  # Alias used by some specs; same semantics as choose.
  def self.choose_evt(evts : Array(Event(T))) : Event(T) forall T
    choose(evts)
  end

  # Creates an interval timeout event that completes periodically with the symbol `:timeout`.
  # Useful for creating recurring time-limited operations.
  def self.timeout_interval(interval : Time::Span) : Event(Symbol)
    IntervalTimerEvent.new(timer_wheel, interval)
  end

  # Varargs convenience overloads to avoid constructing arrays at call sites.
  def self.choose(*evts : Event(T)) : Event(T) forall T
    choose(evts.to_a)
  end

  def self.choose_evt(*evts : Event(T)) : Event(T) forall T
    choose(evts.to_a)
  end
end

require "./timer_wheel"
require "./ivar"
require "./mvar"
