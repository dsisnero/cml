module CML
  # -----------------------
  # Simple DSL Helpers
  # -----------------------
  # Usage:
  #   CML.after(1.second) { puts "done" }
  #   CML.spawn_evt { ... }

  # Runs a block after a given time span, in a new fiber.
  def self.after(span : Time::Span, &block : ->)
    ch = Channel(Nil).new(1)
    spawn do
      sync(timeout(span))
      block.call
      ch.send(nil)
    end
    ch
  end

  # Spawns a new fiber to run the given block, returning an event that completes when the block finishes.
  def self.spawn_evt(&block : -> T) : Event(T) forall T
    ch = Chan(T).new
    spawn do
      begin
        CML.sync(ch.send_evt(block.call))
      rescue ex
        # Send exception as a failure event if needed
        # For now, just ignore to keep API simple
      end
    end
    ch.recv_evt
  end

  # -----------------------
  # Choose macro (unified event choice)
  # -----------------------
  # Usage:
  #   CML.choose(evt1, evt2, evt3)
  #   CML.choose(*events_array)
  macro choose(*evts)
    {% if evts.size == 0 %}
      {% raise "CML.choose requires at least one event" %}
    {% end %}

    {% if evts.size == 1 && evts[0].is_a?(ArrayLiteral) %}
      # Handle array literal input: CML.choose([evt1, evt2])
      CML.__choose_from_array({{ evts[0] }})
    {% elsif evts.size == 1 %}
      # Single argument - could be a single event or an array variable
      # Use the method overloads directly to avoid infinite macro recursion
      CML.__choose_single({{ evts[0] }})
    {% else %}
      # Handle varargs: CML.choose(evt1, evt2, evt3)
      # For more than 6 arguments, use the array-based approach
      {% if evts.size > 6 %}
        CML.__choose_impl({{ evts.splat }})
      {% else %}
        # For 2-6 arguments, use the appropriate varargs method
        {% if evts.size == 2 %}
          CML.__choose_varargs_2({{ evts[0] }}, {{ evts[1] }})
        {% elsif evts.size == 3 %}
          CML.__choose_varargs_3({{ evts[0] }}, {{ evts[1] }}, {{ evts[2] }})
        {% elsif evts.size == 4 %}
          CML.__choose_varargs_4({{ evts[0] }}, {{ evts[1] }}, {{ evts[2] }}, {{ evts[3] }})
        {% elsif evts.size == 5 %}
          CML.__choose_varargs_5({{ evts[0] }}, {{ evts[1] }}, {{ evts[2] }}, {{ evts[3] }}, {{ evts[4] }})
        {% elsif evts.size == 6 %}
          CML.__choose_varargs_6({{ evts[0] }}, {{ evts[1] }}, {{ evts[2] }}, {{ evts[3] }}, {{ evts[4] }}, {{ evts[5] }})
        {% end %}
      {% end %}
    {% end %}
  end

  # -----------------------
  # -----------------------
  # Select (SML/NJ CML compatible)
  # -----------------------
  # Equivalent to SML's: val select : 'a event list -> 'a
  # This is simply sync(choose(events))
  #
  # Usage:
  #   CML.select([evt1, evt2, evt3])
  #   CML.select(ch1.recv_evt, ch2.recv_evt)  # varargs form
  def self.select(events : Array(Event(T))) : T forall T
    sync(choose(events))
  end

  # Varargs form of select for convenience
  macro select(*evts)
    {% if evts.size == 1 && evts[0].is_a?(ArrayLiteral) %}
      CML.sync(CML.choose({{ evts[0] }}))
    {% elsif evts.size == 1 %}
      CML.sync(CML.__choose_single({{ evts[0] }}))
    {% else %}
      CML.sync(CML.choose({{ evts.splat }}))
    {% end %}
  end

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
    @event_id : Int64 = CML::Tracer.next_event_id
    @done = Channel(Nil).new(1)
    @decided = Atomic(Bool).new(false)
    @cancellations = Array(Proc(Nil)).new
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

      cancellations_to_run = Array(Proc(Nil)).new
      made_decision = false

      @mtx.synchronize do
        if @decided.compare_and_set(false, true)
          @winner = value
          @done.send(nil) rescue nil
          cancellations_to_run = @cancellations
          @cancellations = Array(Proc(Nil)).new # Clear to prevent re-entry
          made_decision = true
        end
      end

      if made_decision
        CML.trace "Pick.committed", @event_id, value, tag: "pick"
        cancellations_to_run.each &.call
      else
        CML.trace "Pick.cancelled", @event_id, tag: "pick"
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
  # EventLike abstraction
  # -----------------------
  # Abstract module for all CML events that can be mixed in choose/select.
  # This allows both typed and void events to be mixed without explicit superclasses.
  module EventLike
    # Unique event id for tracing
    property event_id : Int64 = CML::Tracer.next_event_id

    # A polling mechanism for `choose` to check for an immediate result
    # without the overhead of a full registration.
    # The default is to return nil, indicating no immediate value.
    # `AlwaysEvt` will override this.
    def poll
      nil
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
    include EventLike

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
  # An event that always succeeds immediately with a fixed value.
  # Atomicity: Registration is non-blocking and always completes instantly.
  # Fiber behavior: No fiber is blocked; result is available immediately.
  class AlwaysEvt(T) < Event(T)
    def initialize(@value : T)
    end

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
  # An event that never succeeds.
  # Atomicity: Registration is non-blocking and never completes.
  # Fiber behavior: Any fiber waiting on this event will block forever.
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
  # A channel for communicating values between concurrent processes.
  # Channels support both send and receive operations as events.
  # Atomicity: Registration is non-blocking; rendezvous is atomic.
  # Fiber behavior: Fibers block only in sync, not in registration.
  class Chan(T)
    @closed = Atomic(Bool).new(false)

    # Closes the channel. Further sends or receives will fail.
    def close
      @closed.set(true)
    end

    def closed?
      @closed.get
    end

    @send_q = Deque({T, Pick(Nil)}).new
    @recv_q = Deque(Pick(T)).new
    @mtx = Mutex.new

    # Blocking send - sends a value on the channel
    # Blocks until a receiver is ready
    def send(value : T) : Nil
      CML.sync(send_evt(value))
    end

    # Blocking receive - receives a value from the channel
    # Blocks until a sender is ready
    def recv : T
      CML.sync(recv_evt)
    end

    # Creates a send event for the given value.
    # The event completes when the value is successfully sent.
    def send_evt(value : T) : Event(Nil)
      raise Channel::ClosedError.new("send on closed channel") if closed?
      SendEvt.new(self, value)
    end

    # Creates a receive event.
    # The event completes when a value is received from the channel.
    def recv_evt : Event(T)
      raise Channel::ClosedError.new("recv on closed channel") if closed?
      RecvEvt.new(self)
    end

    # Non-blocking send poll.
    # Returns true if a receiver is waiting and the value was delivered.
    # Equivalent to SML's: val sendPoll : ('a chan * 'a) -> bool
    def send_poll(value : T) : Bool
      @mtx.synchronize do
        if recv_pick = @recv_q.shift?
          # Found a waiting receiver, complete the rendezvous
          recv_pick.try_decide(value)
          return true
        end
      end
      false
    end

    # Non-blocking receive poll.
    # Returns the value if a sender is waiting, nil otherwise.
    # Equivalent to SML's: val recvPoll : 'a chan -> 'a option
    def recv_poll : T?
      @mtx.synchronize do
        if pair = @send_q.shift?
          value, send_pick = pair
          send_pick.try_decide(nil)
          return value
        end
      end
      nil
    end

    # Registers a send operation with the channel.
    # If a receiver is waiting, the value is immediately delivered.
    # Otherwise, the send is queued until a receiver arrives.
    def register_send(value : T, pick : Pick(Nil)) : Proc(Nil)
      offer = {value, pick}
      CML.trace "Chan.register_send", value, pick, pick.@event_id, tag: "chan"

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
        CML.trace "Chan.send_committed", value, pick, pick.@event_id, tag: "chan"
        return -> { } # Rendezvous complete, no-op cancel
      end

      # Return a cancellation proc that removes from the send queue
      -> {
        @mtx.synchronize { @send_q.delete(offer) rescue nil }
        CML.trace "Chan.send_cancelled", value, pick, pick.@event_id, tag: "chan"
      }
    end

    # Registers a receive operation with the channel.
    # If a sender is waiting, the value is immediately received.
    # Otherwise, the receive is queued until a sender arrives.
    def register_recv(pick : Pick(T)) : Proc(Nil)
      CML.trace "Chan.register_recv", self, pick, pick.@event_id, tag: "chan"

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
        CML.trace "Chan.recv_committed", pick, value, pick.@event_id, tag: "chan"
        return -> { } # Rendezvous complete, no-op cancel
      end

      # Return a cancellation proc that removes from the receive queue
      -> {
        @mtx.synchronize { @recv_q.delete(offer) rescue nil }
        CML.trace "Chan.recv_cancelled", pick, pick.@event_id, tag: "chan"
      }
    end
  end

  # An event representing a send operation on a channel.
  # Completes when the value is successfully sent.
  # An event representing a send operation on a channel.
  # Completes when the value is successfully sent.
  # Atomicity: Registration is non-blocking; commit is atomic.
  # Fiber behavior: Sender fiber blocks only in sync, not in registration.
  # An event representing a send operation on a channel.
  # Completes when a value is successfully sent.
  #
  # Atomicity: Registration is non-blocking; commit is atomic.
  # Fiber behavior: Sender fiber blocks only in sync, not in registration.
  class SendEvt(T) < Event(Nil)
    def initialize(@ch : Chan(T), @val : T)
    end

    # Registers this send event with a pick.
    def try_register(pick : Pick(Nil)) : Proc(Nil)
      @ch.register_send(@val, pick)
    end
  end

  # An event representing a receive operation on a channel.
  # Completes when a value is successfully received.
  # An event representing a receive operation on a channel.
  # Completes when a value is successfully received.
  # Atomicity: Registration is non-blocking; commit is atomic.
  # Fiber behavior: Receiver fiber blocks only in sync, not in registration.
  class RecvEvt(T) < Event(T)
    def initialize(@ch : Chan(T))
    end

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
  # An event that completes after a specified duration with the symbol `:timeout`.
  # Useful for creating time-limited operations in conjunction with `choose`.
  # Atomicity: Registration is non-blocking; commit is atomic when timer fires.
  # Fiber behavior: Fiber blocks only in sync, not in registration.
  class TimeoutEvt < Event(Symbol)
    # Creates a new timeout event.
    def initialize(@duration : Time::Span)
    end

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
  # An event that transforms the result of another event.
  # The transformation function is applied after the inner event completes.
  # Atomicity: Registration is non-blocking; commit is atomic after inner event.
  # Fiber behavior: Fiber blocks only in sync, not in registration.
  class WrapEvt(A, B) < Event(B)
    def initialize(@inner : Event(A), &@f : A -> B)
    end

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
      return unless inner_val = @inner.poll
      @f.call(inner_val)
    end
  end

  # -----------------------
  # WrapAbort (wrap with abort on cancel)
  # -----------------------
  # Like wrap, but runs an abort callback if the event is cancelled (loses a choose).
  #
  # @type A The result type of the inner event
  # @type B The result type after transformation
  # Like wrap, but runs an abort callback if the event is cancelled (loses a choose).
  # Atomicity: Registration is non-blocking; commit is atomic after inner event.
  # Fiber behavior: Fiber blocks only in sync, not in registration. Abort callback runs if cancelled.
  class WrapAbortEvt(A, B) < Event(B)
    def initialize(@inner : Event(A), @on_abort : -> Nil, &@f : A -> B)
    end

    def try_register(pick : Pick(B)) : Proc(Nil)
      inner_pick = Pick(A).new
      cancel_inner = @inner.try_register(inner_pick)
      won = Atomic(Bool).new(false)
      spawn do
        inner_pick.wait
        if inner_pick.decided?
          won.set(true)
          pick.try_decide(@f.call(inner_pick.value))
        end
      end
      -> {
        unless won.get
          @on_abort.call
        end
        cancel_inner.call
      }
    end

    def poll : B?
      return unless inner_val = @inner.poll
      @f.call(inner_val)
    end
  end

  # Public API for wrap_abort
  def self.wrap_abort(evt : Event(A), on_abort : -> Nil, &block : A -> B) : Event(B) forall A, B
    WrapAbortEvt(A, B).new(evt, on_abort, &block)
  end

  # -----------------------
  # Guard (defer creation until sync)
  # -----------------------
  # An event that defers creation of its inner event until synchronization time.
  # Useful for creating events that depend on runtime state.
  #
  # @type T The result type of the guarded event
  # An event that defers creation of its inner event until synchronization time.
  # Useful for creating events that depend on runtime state.
  # Atomicity: Registration is non-blocking; commit is atomic after inner event.
  # Fiber behavior: Fiber blocks only in sync, not in registration.
  #
  # Implementation note: We store a register_thunk that directly calls try_register
  # on the inner event. This avoids the need to cast the inner event to Event(T),
  # which triggers a Crystal compiler bug with generic type downcasting.
  class GuardEvt(T) < Event(T)
    # Instead of storing the event-creating thunk, we store a thunk that
    # directly performs registration. This avoids generic downcasting issues.
    @register_thunk : Pick(T) -> Proc(Nil)

    # Creates a new guard event.
    # The block must return an Event(T). We capture the registration behavior.
    def initialize(&block : -> E) forall E
      # Create a registration thunk that:
      # 1. Calls the user's block to get the inner event
      # 2. Calls try_register on that event
      # This is done without storing Event(T) directly, avoiding the downcast.
      @register_thunk = ->(pick : Pick(T)) : Proc(Nil) {
        inner_evt = block.call
        # The inner event's type E is a subtype of Event(T)
        # We call try_register polymorphically without explicit cast
        inner_evt.try_register(pick)
      }
    end

    # Registers this guard event with a pick.
    # Invokes the registration thunk which creates and registers the inner event.
    def try_register(pick : Pick(T)) : Proc(Nil)
      @register_thunk.call(pick)
    end

    # When a `GuardEvt` is polled, it must execute its block to get the
    # real event, and then poll that event. This ensures the guard's
    # side-effects are triggered correctly during the polling phase.
    def poll : T?
      # Strict CML laziness: do not evaluate the guard thunk during poll.
      # This prevents side effects from running in ChooseEvt's poll fast path.
      # The thunk will be evaluated only during registration (try_register).
      nil
    end
  end

  # -----------------------
  # Nack (run on cancel)
  # -----------------------
  # An event that runs a callback when it loses in a choice.
  # The callback is executed only if this event is registered but not chosen.
  #
  # @type T The result type of the inner event
  # An event that runs a callback when it loses in a choice.
  # The callback is executed only if this event is registered but not chosen.
  # Atomicity: Registration is non-blocking; commit is atomic after inner event.
  # Fiber behavior: Fiber blocks only in sync, not in registration. Cancel callback runs if not chosen.
  class NackEvt(T) < Event(T)
    # Creates a new nack event.
    def initialize(@inner : Event(T), &@on_cancel : -> Nil)
    end

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
  # An event that represents a choice between multiple events.
  # The first event to complete wins and decides the pick. All others are cancelled.
  # Atomicity: Registration is non-blocking; commit is atomic for the winner.
  # Fiber behavior: Fiber blocks only in sync, not in registration. All losers are cancelled.
  class ChooseEvt(T) < Event(T)
    getter evts : Array(Event(T))

    # Accept arrays of Event or any Event subtype (e.g., Array(RecvEvt(T))).
    def initialize(evts : Array(E)) forall E
      @evts = evts.map(&.as(Event(T)))
    end

    # Poll the choice - returns the first immediately-ready value
    def poll : T?
      @evts.each do |evt|
        if value = evt.poll
          return value
        end
      end
      nil
    end

    # Registers all events in the choice with the pick.
    # The first event to complete decides the pick,
    # and all other events are cancelled.
    #
    # CML Semantics: Guards must be forced before polling. The sequence is:
    # 1. Force all guards (evaluate thunks, get inner events)
    # 2. Poll all base events for immediate readiness
    # 3. If none ready, register and block
    def try_register(pick : Pick(T)) : Proc(Nil)
      CML.trace "ChooseEvt.try_register", self, pick, @event_id, tag: "choose"

      # Separate guards from base events
      # Guards need to be forced (registered) before we can poll their inner events
      has_guards = @evts.any? { |e| e.is_a?(GuardEvt(T)) }

      if has_guards
        # If we have guards, we must register everything first (forcing guards)
        # then the pick will be decided by whatever event is immediately ready
        @evts.each do |evt|
          pick.add_cancel(evt.try_register(pick))
        end

        # After forcing guards, check if pick was decided by an immediately-ready event
        CML.trace "ChooseEvt.registered_with_guards", self, pick, @event_id, tag: "choose"
      else
        # --- Polling Optimization (only for base events, no guards) ---
        @evts.each do |evt|
          if value = evt.poll
            if pick.try_decide(value)
              CML.trace "ChooseEvt.committed", self, pick, @event_id, tag: "choose"
              return -> { } # Immediate win, no cancellation needed.
            end
          end
        end

        # --- Asynchronous Registration ---
        @evts.each do |evt|
          pick.add_cancel(evt.try_register(pick))
        end
      end

      # The cancellation proc for the ChooseEvt itself is a no-op.
      -> {
        CML.trace "ChooseEvt.cancelled", self, pick, @event_id, tag: "choose"
      }
    end
  end

  # -----------------------
  # Future primitives (stubs)
  # -----------------------
  # These are placeholders so specs can compile while the primitives are pending.
  # They raise at registration time if accidentally used.
  class NotImplementedEvt(T) < Event(T)
    def initialize(@feature : String)
    end

    def try_register(pick : Pick(T)) : Proc(Nil)
      raise "Not implemented: #{@feature}"
    end
  end

  # -----------------------
  # Timer Wheel Events
  # -----------------------
  # Timer event that uses the TimerWheel for efficient timeout management
  # Timer event that uses the TimerWheel for efficient timeout management.
  # Atomicity: Registration is non-blocking; commit is atomic when timer fires.
  # Fiber behavior: Fiber blocks only in sync, not in registration.
  class TimerEvent < Event(Symbol)
    @timer_id : UInt64?
    @pick = Atomic(Pick(Symbol)?).new(nil)

    def initialize(@timer_wheel : TimerWheel, @duration : Time::Span)
    end

    def try_register(pick : Pick(Symbol)) : Proc(Nil)
      @pick.set(pick)
      # Schedule the timer with the wheel
      @timer_id = @timer_wheel.schedule(@duration) do
        # Use atomic reference to prevent race conditions
        if current_pick = @pick.swap(nil)
          current_pick.try_decide(:timeout)
        end
      end

      # Return cancellation proc
      -> {
        # Prevent the timer from firing by clearing the pick atomically
        @pick.set(nil)
        return unless timer_id = @timer_id
        @timer_wheel.cancel(timer_id)
      }
    end
  end # Interval timer event for recurring timeouts
  # Interval timer event for recurring timeouts.
  # Atomicity: Registration is non-blocking; commit is atomic when timer fires.
  # Fiber behavior: Fiber blocks only in sync, not in registration.
  class IntervalTimerEvent < Event(Symbol)
    @timer_id : UInt64?
    @pick = Atomic(Pick(Symbol)?).new(nil)

    def initialize(@timer_wheel : TimerWheel, @interval : Time::Span)
    end

    def try_register(pick : Pick(Symbol)) : Proc(Nil)
      @pick.set(pick)
      # Schedule the interval timer with the wheel
      @timer_id = @timer_wheel.schedule_interval(@interval) do
        # Use atomic reference to prevent race conditions
        if current_pick = @pick.get
          current_pick.try_decide(:timeout)
        end
      end

      # Return cancellation proc
      -> {
        # Prevent the timer from firing by clearing the pick atomically
        @pick.set(nil)
        return unless timer_id = @timer_id
        @timer_wheel.cancel(timer_id)
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
  # Note: Use `time_out_evt` for SML-compatible unit event.
  def self.timeout(duration : Time::Span) : Event(Symbol)
    TimeoutEvt.new(duration)
  end

  # Equivalent to SML's: val timeOutEvt : Time.time -> unit event
  # Creates a timeout event that yields unit (Nil) after the duration.
  def self.time_out_evt(duration : Time::Span) : Event(Nil)
    TimeOutEvt.new(duration)
  end

  # Equivalent to SML's: val atTimeEvt : Time.time -> unit event
  # Creates an event that triggers at an absolute time.
  def self.at_time_evt(time : Time) : Event(Nil)
    duration = time - Time.utc
    duration = Time::Span.zero if duration.negative?
    TimeOutEvt.new(duration)
  end

  # Creates an event that transforms the result of another event.
  # The transformation is applied after the inner event completes.
  def self.wrap(evt : Event(A), &block : A -> B) : Event(B) forall A, B
    wrap_evt = WrapEvt(A, B).new(evt, &block)
    wrap_evt.event_id = evt.event_id
    wrap_evt
  end

  # Creates an event that defers creation of its inner event until synchronization time.
  # Useful for creating events that depend on runtime state.
  # The block must return an Event(T) - all branches must return the same event result type.
  def self.guard(&block : -> Event(T)) : Event(T) forall T
    GuardEvt(T).new(&block)
  end

  # Creates an event that runs a callback when it loses in a choice.
  # The callback is executed only if this event is registered but not chosen.
  def self.nack(evt : Event(T), &block : -> Nil) : Event(T) forall T
    nack_evt = NackEvt(T).new(evt, &block)
    nack_evt.event_id = evt.event_id
    nack_evt
  end

  # Internal implementation for macro-based choose
  def self.__choose_impl(*evts : EventLike)
    raise ArgumentError.new("choose requires at least one event") if evts.size < 1

    # Single event case - return as proper Event type
    return evts.first.as(Event) if evts.size == 1

    # For multiple events, use the appropriate varargs choose method
    case evts.size
    when 2
      __choose_varargs_2(evts[0].as(Event), evts[1].as(Event))
    when 3
      __choose_varargs_3(evts[0].as(Event), evts[1].as(Event), evts[2].as(Event))
    when 4
      __choose_varargs_4(evts[0].as(Event), evts[1].as(Event), evts[2].as(Event), evts[3].as(Event))
    when 5
      __choose_varargs_5(evts[0].as(Event), evts[1].as(Event), evts[2].as(Event), evts[3].as(Event), evts[4].as(Event))
    when 6
      __choose_varargs_6(evts[0].as(Event), evts[1].as(Event), evts[2].as(Event), evts[3].as(Event), evts[4].as(Event), evts[5].as(Event))
    else
      # For more than 6 events, use the array-based approach
      events_array = evts.to_a.map(&.as(Event))
      __choose_from_array(events_array)
    end
  end

  # Overload to handle arrays from nested choose calls
  def self.__choose_impl(evts : Array(EventLike))
    __choose_from_array(evts)
  end

  # Creates a choice event from an array of events.
  # Note: We intentionally keep this generic (Event(T)).
  # Crystal infers T from the arguments; returning a non-generic Event
  # would break sync(evt : Event(T)) which relies on T for the result type.
  # Keep existing choose method for homogeneous arrays
  def self.choose(evts : Array(Event(T))) : Event(T) forall T
    case evts.size
    when 0
      # Empty choice is never ready - return a NeverEvt
      NeverEvt(T).new
    when 1
      evts.first
    else
      flat = evts.flat_map { |e| e.is_a?(ChooseEvt(T)) ? e.evts : [e] }
      ChooseEvt(T).new(flat)
    end
  end

  # Add explicit overload for Event arrays (non-generic)
  def self.choose(evts : Array(Event)) : Event
    case evts.size
    when 0
      raise ArgumentError.new("choose requires at least one event")
    when 1
      evts.first
    else
      # For non-generic Event arrays, delegate to the union handler
      __choose_heterogeneous_impl(evts)
    end
  end

  # Handle single argument to choose macro - dispatches to appropriate method
  # This is used by the macro to avoid infinite recursion
  # IMPORTANT: These methods must NOT call the choose macro/method, they must
  # call the implementation directly to avoid infinite recursion.
  def self.__choose_single(evt : Event(T)) : Event(T) forall T
    evt
  end

  def self.__choose_single(evts : Array(Event(T))) : Event(T) forall T
    # Call the implementation directly, NOT choose() which would trigger the macro
    case evts.size
    when 0
      NeverEvt(T).new
    when 1
      evts.first
    else
      flat = evts.flat_map { |e| e.is_a?(ChooseEvt(T)) ? e.evts : [e] }
      ChooseEvt(T).new(flat)
    end
  end

  def self.__choose_single(evts : Array(Event)) : Event
    # Call the implementation directly
    case evts.size
    when 0
      raise ArgumentError.new("choose requires at least one event")
    when 1
      evts.first
    else
      __choose_heterogeneous_impl(evts)
    end
  end

  def self.__choose_single(evts : Array(EventLike))
    __choose_from_array(evts)
  end

  # Fixed __choose_from_array to break recursion cycle
  def self.__choose_from_array(evts : Array(Event(T))) : Event(T) forall T
    case evts.size
    when 0
      raise ArgumentError.new("choose requires at least one event")
    when 1
      evts.first
    else
      # Convert EventLike to proper Event types and use direct ChooseEvt creation
      # This avoids calling choose() method which would go back through the macro
      flat = evts.flat_map { |e| e.is_a?(ChooseEvt(T)) ? e.evts : [e] }
      ChooseEvt(T).new(flat)
    end
  end

  # Overload for EventLike arrays to handle type unification
  def self.__choose_from_array(evts : Array(EventLike))
    # For EventLike arrays, we need to handle type unification
    # Convert to proper Event types and use the appropriate choose method
    case evts.size
    when 0
      raise ArgumentError.new("choose requires at least one event")
    when 1
      evts.first.as(Event)
    else
      # For multiple events, convert to Event array and use choose
      # This handles type unification through Crystal's type system
      events = evts.map { |e| e.as(Event) }
      __choose_heterogeneous_impl(events)
    end
  end

  # Handle heterogeneous event types by creating proper union type
  private def self.__choose_heterogeneous_impl(evts : Array(Event))
    case evts.size
    when 0
      raise ArgumentError.new("choose requires at least one event")
    when 1
      evts.first
    else
      # For heterogeneous types, we need to create a unified type
      # Since we can't easily determine the union type at runtime,
      # we'll use a different approach: create a ChooseEvt with the base Event type
      # This will work because all events are subtypes of Event
      unified_events = evts.map { |e| e.as(Event) }
      ChooseEvt(NoReturn).new(unified_events)
    end
  end

  # Helper methods for varargs choose to avoid macro recursion
  def self.__choose_varargs_2(e1 : Event(A), e2 : Event(B)) : Event(A | B) forall A, B
    events = [] of Event(A | B)
    events << wrap(e1) { |x| x.as(A | B) }
    events << wrap(e2) { |x| x.as(A | B) }
    __choose_from_array(events)
  end

  def self.__choose_varargs_3(e1 : Event(A), e2 : Event(B), e3 : Event(C)) : Event(A | B | C) forall A, B, C
    events = [] of Event(A | B | C)
    events << wrap(e1) { |x| x.as(A | B | C) }
    events << wrap(e2) { |x| x.as(A | B | C) }
    events << wrap(e3) { |x| x.as(A | B | C) }
    __choose_from_array(events)
  end

  def self.__choose_varargs_4(e1 : Event(A), e2 : Event(B), e3 : Event(C), e4 : Event(D)) : Event(A | B | C | D) forall A, B, C, D
    events = [] of Event(A | B | C | D)
    events << wrap(e1) { |x| x.as(A | B | C | D) }
    events << wrap(e2) { |x| x.as(A | B | C | D) }
    events << wrap(e3) { |x| x.as(A | B | C | D) }
    events << wrap(e4) { |x| x.as(A | B | C | D) }
    __choose_from_array(events)
  end

  def self.__choose_varargs_5(e1 : Event(A), e2 : Event(B), e3 : Event(C), e4 : Event(D), e5 : Event(E)) : Event(A | B | C | D | E) forall A, B, C, D, E
    events = [] of Event(A | B | C | D | E)
    events << wrap(e1) { |x| x.as(A | B | C | D | E) }
    events << wrap(e2) { |x| x.as(A | B | C | D | E) }
    events << wrap(e3) { |x| x.as(A | B | C | D | E) }
    events << wrap(e4) { |x| x.as(A | B | C | D | E) }
    events << wrap(e5) { |x| x.as(A | B | C | D | E) }
    __choose_from_array(events)
  end

  def self.__choose_varargs_6(e1 : Event(A), e2 : Event(B), e3 : Event(C), e4 : Event(D), e5 : Event(E), e6 : Event(F)) : Event(A | B | C | D | E | F) forall A, B, C, D, E, F
    events = [] of Event(A | B | C | D | E | F)
    events << wrap(e1) { |x| x.as(A | B | C | D | E | F) }
    events << wrap(e2) { |x| x.as(A | B | C | D | E | F) }
    events << wrap(e3) { |x| x.as(A | B | C | D | E | F) }
    events << wrap(e4) { |x| x.as(A | B | C | D | E | F) }
    events << wrap(e5) { |x| x.as(A | B | C | D | E | F) }
    events << wrap(e6) { |x| x.as(A | B | C | D | E | F) }
    __choose_from_array(events)
  end

  # Varargs choose overloads for heterogeneous event result types (2..6 args).
  # These construct a homogeneous Array(Event(union)) via wrap-based upcasting
  # and delegate to the array-based choose implementation.
  def self.choose(e1 : Event(A), e2 : Event(B)) : Event(A | B) forall A, B
    events = [] of Event(A | B)
    events << wrap(e1) { |x| x.as(A | B) }
    events << wrap(e2) { |x| x.as(A | B) }
    choose(events)
  end

  def self.choose(e1 : Event(A), e2 : Event(B), e3 : Event(C)) : Event(A | B | C) forall A, B, C
    events = [] of Event(A | B | C)
    events << wrap(e1) { |x| x.as(A | B | C) }
    events << wrap(e2) { |x| x.as(A | B | C) }
    events << wrap(e3) { |x| x.as(A | B | C) }
    choose(events)
  end

  def self.choose(e1 : Event(A), e2 : Event(B), e3 : Event(C), e4 : Event(D)) : Event(A | B | C | D) forall A, B, C, D
    events = [] of Event(A | B | C | D)
    events << wrap(e1) { |x| x.as(A | B | C | D) }
    events << wrap(e2) { |x| x.as(A | B | C | D) }
    events << wrap(e3) { |x| x.as(A | B | C | D) }
    events << wrap(e4) { |x| x.as(A | B | C | D) }
    choose(events)
  end

  def self.choose(e1 : Event(A), e2 : Event(B), e3 : Event(C), e4 : Event(D), e5 : Event(E)) : Event(A | B | C | D | E) forall A, B, C, D, E
    events = [] of Event(A | B | C | D | E)
    events << wrap(e1) { |x| x.as(A | B | C | D | E) }
    events << wrap(e2) { |x| x.as(A | B | C | D | E) }
    events << wrap(e3) { |x| x.as(A | B | C | D | E) }
    events << wrap(e4) { |x| x.as(A | B | C | D | E) }
    events << wrap(e5) { |x| x.as(A | B | C | D | E) }
    choose(events)
  end

  def self.choose(e1 : Event(A), e2 : Event(B), e3 : Event(C), e4 : Event(D), e5 : Event(E), e6 : Event(F)) : Event(A | B | C | D | E | F) forall A, B, C, D, E, F
    events = [] of Event(A | B | C | D | E | F)
    events << wrap(e1) { |x| x.as(A | B | C | D | E | F) }
    events << wrap(e2) { |x| x.as(A | B | C | D | E | F) }
    events << wrap(e3) { |x| x.as(A | B | C | D | E | F) }
    events << wrap(e4) { |x| x.as(A | B | C | D | E | F) }
    events << wrap(e5) { |x| x.as(A | B | C | D | E | F) }
    events << wrap(e6) { |x| x.as(A | B | C | D | E | F) }
    choose(events)
  end

  # Alias used by some specs; same semantics as choose.
  def self.choose_evt(evts : Array(Event(T))) : Event(T) forall T
    choose(evts)
  end

  # Creates an event that synchronizes on all immediately ready events.
  # Returns an array of results for all events that can complete now.
  # If none are ready, synchronizes on the first to complete.
  def self.choose_all(evts : Array(Event(T))) : Event(Array(T)) forall T
    return AlwaysEvt(Array(T)).new(Array(T).new) if evts.empty?
    ready = evts.compact_map(&.poll)
    if !ready.empty?
      AlwaysEvt(Array(T)).new(ready)
    else
      # Fallback: synchronize on the first event to complete, wrap in array
      WrapEvt(T, Array(T)).new(ChooseEvt(T).new(evts)) { |x| [x] }
    end
  end

  def self.choose_all(*evts : Event(T)) : Event(Array(T)) forall T
    choose_all(evts.to_a)
  end

  # Creates an interval timeout event that completes periodically with the symbol `:timeout`.
  # Useful for creating recurring time-limited operations.
  def self.timeout_interval(interval : Time::Span) : Event(Symbol)
    IntervalTimerEvent.new(timer_wheel, interval)
  end

  # Races an event against a timeout. Returns a tagged tuple: {result, :ok} or {nil, :timeout}
  def self.with_timeout(evt : Event(T), span : Time::Span) : Event(Tuple(T?, Symbol)) forall T
    # Use the varargs choose to avoid complex array typing issues
    choose(
      wrap(evt) { |v| {v, :ok} },
      wrap(timeout(span)) { |_| {nil.as(T?), :timeout} },
    )
  end

  # ===========================================================================
  # Modern CML API (matching SML/NJ CML)
  # ===========================================================================
  # These functions provide the modern CML API as defined in SML/NJ.
  # The old API (0.9.8) is available in src/cml/old_cml.cr for compatibility.

  # -----------------------
  # Event API (EVENT signature)
  # -----------------------

  # An event that always succeeds immediately with the given value.
  # Modern CML name for `always`.
  # Equivalent to SML's: val alwaysEvt : 'a -> 'a event
  def self.always_evt(x : T) : Event(T) forall T
    AlwaysEvt(T).new(x)
  end

  # An event that always succeeds with nil (unit).
  # Equivalent to SML's: alwaysEvt()
  def self.always_evt : Event(Nil)
    AlwaysEvt(Nil).new(nil)
  end

  # Creates an event with a negative acknowledgment callback.
  # The callback receives an event that fires if this branch loses in a choose.
  # Equivalent to SML's: val withNack : (unit event -> 'a event) -> 'a event
  def self.with_nack(&block : Event(Nil) -> Event(T)) : Event(T) forall T
    WithNackEvt(T).new(&block)
  end

  # Wraps an event with an exception handler.
  # If the wrapped event raises, the handler is called.
  # Equivalent to SML's: val wrapHandler : ('a event * (exn -> 'a)) -> 'a event
  def self.wrap_handler(evt : Event(T), &handler : Exception -> T) : Event(T) forall T
    WrapHandlerEvt(T).new(evt, handler)
  end

  # Synchronizes on the first event from a list to complete.
  # Equivalent to SML's: val select : 'a event list -> 'a
  def self.select(evts : Array(Event(T))) : T forall T
    sync(choose(evts))
  end

  # -----------------------
  # Channel API (CHANNEL signature)
  # -----------------------

  # Creates a new channel.
  # Equivalent to SML's: val channel : unit -> 'a chan
  def self.channel(type : T.class) : Chan(T) forall T
    Chan(T).new
  end

  # Checks if two channels are the same.
  # Equivalent to SML's: val sameChannel : ('a chan * 'a chan) -> bool
  def self.same_channel(ch1 : Chan(T), ch2 : Chan(T)) : Bool forall T
    ch1.same?(ch2)
  end

  # Sends a value on a channel (blocking).
  # Equivalent to SML's: val send : ('a chan * 'a) -> unit
  def self.send(ch : Chan(T), value : T) forall T
    sync(ch.send_evt(value))
  end

  # Receives a value from a channel (blocking).
  # Equivalent to SML's: val recv : 'a chan -> 'a
  def self.recv(ch : Chan(T)) : T forall T
    sync(ch.recv_evt)
  end

  # Non-blocking send attempt.
  # Returns true if the send succeeded immediately, false otherwise.
  # Equivalent to SML's: val sendPoll : ('a chan * 'a) -> bool
  def self.send_poll(ch : Chan(T), value : T) : Bool forall T
    ch.send_poll(value)
  end

  # Non-blocking receive attempt.
  # Returns the value if one is available, nil otherwise.
  # Equivalent to SML's: val recvPoll : 'a chan -> 'a option
  def self.recv_poll(ch : Chan(T)) : T? forall T
    ch.recv_poll
  end

  # -----------------------
  # Timeout API (TIME_OUT signature)
  # -----------------------

  # Creates a timeout event that fires after the given duration.
  # Equivalent to SML's: val timeOutEvt : Time.time -> unit event
  def self.time_out_evt(duration : Time::Span) : Event(Nil)
    TimeOutEvt.new(duration)
  end

  # Creates an event that fires at a specific time.
  # Equivalent to SML's: val atTimeEvt : Time.time -> unit event
  def self.at_time_evt(time : Time) : Event(Nil)
    duration = time - Time.utc
    if duration.positive?
      TimeOutEvt.new(duration)
    else
      AlwaysEvt(Nil).new(nil)
    end
  end

  # -----------------------
  # Thread API (THREAD signature)
  # -----------------------

  # Thread ID type - wraps fiber with completion signaling (like SML/NJ's TID with dead cvar)
  class CmlThreadId
    getter fiber : Fiber
    getter dead : IVar(Nil)

    def initialize(@fiber : Fiber, @dead : IVar(Nil))
    end

    def name : String?
      @fiber.name
    end

    def object_id : UInt64
      @fiber.object_id
    end
  end

  alias ThreadId = CmlThreadId

  # Gets the current thread/fiber ID.
  # Equivalent to SML's: val getTid : unit -> thread_id
  # Note: This returns a lightweight wrapper, not a full CmlThreadId with completion tracking
  def self.tid : Fiber
    Fiber.current
  end

  # Checks if two thread IDs are the same.
  # Equivalent to SML's: val sameTid : (thread_id * thread_id) -> bool
  def self.same_tid(tid1 : ThreadId, tid2 : ThreadId) : Bool
    tid1.fiber == tid2.fiber
  end

  # Compares two thread IDs for ordering.
  # Equivalent to SML's: val compareTid : (thread_id * thread_id) -> order
  def self.compare_tid(tid1 : ThreadId, tid2 : ThreadId) : Int32
    tid1.object_id <=> tid2.object_id
  end

  # Hash a thread ID.
  # Equivalent to SML's: val hashTid : thread_id -> word
  def self.hash_tid(tid : ThreadId) : UInt64
    tid.object_id.to_u64
  end

  # Convert a thread ID to a string.
  # Equivalent to SML's: val tidToString : thread_id -> string
  def self.tid_to_string(tid : ThreadId) : String
    tid.name || "fiber-#{tid.object_id}"
  end

  # Spawns a new fiber with a curried function.
  # Equivalent to SML's: val spawnc : ('a -> unit) -> 'a -> thread_id
  def self.spawnc(f : Proc(A, Nil)) : Proc(A, ThreadId) forall A
    ->(arg : A) {
      dead = IVar(Nil).new
      fiber = ::spawn do
        begin
          f.call(arg)
        ensure
          dead.i_put(nil) # Signal completion (like SML's notifyAndDispatch)
        end
      end
      CmlThreadId.new(fiber, dead)
    }
  end

  # Spawns a new fiber.
  # Equivalent to SML's: val spawn : (unit -> unit) -> thread_id
  def self.spawn(&block : -> Nil) : ThreadId
    dead = IVar(Nil).new
    fiber = ::spawn do
      begin
        block.call
      ensure
        dead.i_put(nil) # Signal completion (like SML's notifyAndDispatch)
      end
    end
    CmlThreadId.new(fiber, dead)
  end

  # Exits the current fiber.
  # Equivalent to SML's: val exit : unit -> 'a
  def self.exit_thread
    raise FiberExit.new
  end

  # Event that fires when a thread/fiber terminates.
  # Equivalent to SML's: val joinEvt : thread_id -> unit event
  # Uses the IVar in ThreadId (like SML's cvarGetEvt on dead cvar)
  def self.join_evt(tid : ThreadId) : Event(Nil)
    # Simply return the get event for the dead IVar - this is exactly how SML/NJ does it
    tid.dead.i_evt
  end

  # Yields the current fiber.
  # Equivalent to SML's: val yield : unit -> unit
  def self.yield_fiber
    Fiber.yield
  end

  # -----------------------
  # Additional Event Types for Modern API
  # -----------------------

  # Event with negative acknowledgment (withNack)
  private class WithNackEvt(T) < Event(T)
    def initialize(&@block : Event(Nil) -> Event(T))
    end

    def try_register(pick : Pick(T)) : Proc(Nil)
      # Create a channel for the nack signal
      nack_ch = Chan(Nil).new
      nack_evt = nack_ch.recv_evt

      # Create the inner event using the user's block
      inner_evt = @block.call(nack_evt)

      # Register the inner event
      cancel_inner = inner_evt.try_register(pick)

      # Return a cancellation proc that signals the nack
      -> {
        # Signal the nack event when this branch loses
        spawn { CML.sync(nack_ch.send_evt(nil)) rescue nil }
        cancel_inner.call
      }
    end
  end

  # Timeout event that yields Nil (unit) instead of Symbol
  private class TimeOutEvt < Event(Nil)
    def initialize(@duration : Time::Span)
    end

    def try_register(pick : Pick(Nil)) : Proc(Nil)
      timer_id = CML.timer_wheel.schedule(@duration) do
        pick.try_decide(nil)
      end
      -> { CML.timer_wheel.cancel(timer_id) }
    end
  end

  # Exception-handling wrapper for events
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

  # Fiber Exit exception - used by exit_thread
  class FiberExit < Exception
    def initialize
      super("Fiber exit")
    end
  end
end

require "./timer_wheel"
require "./ivar"
require "./mvar"
require "./trace_macro"
require "./cml/mailbox"
require "./cml/multicast_sml"
# require "./cml/linda"
# require "./cml/job"
# Note: Extra performance/metrics files removed - not part of SML/NJ CML or cml-lib
