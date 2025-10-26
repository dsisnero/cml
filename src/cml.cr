# src/cml.cr
# Concurrent ML runtime in Crystal
# Supports: Event, sync, choose, wrap, guard, nack, timeout, channels with cancellation

module CML
  # -----------------------
  # Commit Cell (Pick)
  # -----------------------
  class Pick(T)
    @winner : T? = nil
    @done = Channel(Nil).new(1)
    @decided = Atomic(Bool).new(false)

    def try_decide(value : T) : Bool
      return false if @decided.get
      if @decided.compare_and_set(false, true)
        @winner = value
        @done.send(nil) rescue nil
        true
      else
        false
      end
    end

    def decided? : Bool
      @decided.get
    end

    def value : T
      {% if T == Nil %}
        nil
      {% else %}
        @winner.not_nil!
      {% end %}
    end

    def wait : Nil
      return if decided?
      @done.receive
    end
  end

  # -----------------------
  # Event abstraction
  # -----------------------
  abstract class Event(T)
    abstract def try_register(pick : Pick(T)) : Proc(Nil)
  end

  # -----------------------
  # Basic events
  # -----------------------
  class AlwaysEvt(T) < Event(T)
    def initialize(@value : T); end

    def try_register(pick : Pick(T)) : Proc(Nil)
      pick.try_decide(@value)
      -> { }
    end
  end

  class NeverEvt(T) < Event(T)
    def try_register(pick : Pick(T)) : Proc(Nil)
      -> { }
    end
  end

  # -----------------------
  # Channels
  # -----------------------
  class Chan(T)
    @send_q = Deque({T, Pick(Nil)}).new
    @recv_q = Deque(Pick(T)).new
    @mtx = Mutex.new

    def send_evt(value : T) : Event(Nil)
      SendEvt.new(self, value)
    end

    def recv_evt : Event(T)
      RecvEvt.new(self)
    end

    # Non-blocking registration: enqueue or match immediately
    def register_send(value : T, pick : Pick(Nil)) : Proc(Nil)
      offer = {value, pick}
      matched = false
      @mtx.synchronize do
        if recv_pick = @recv_q.shift?
          recv_pick.try_decide(value)
          pick.try_decide(nil)
          matched = true
        else
          @send_q << offer
        end
      end
      -> { @mtx.synchronize { @send_q.delete(offer) rescue nil } }
    end

    def register_recv(pick : Pick(T)) : Proc(Nil)
      offer = pick
      matched = false
      @mtx.synchronize do
        if pair = @send_q.shift?
          value, send_pick = pair
          send_pick.try_decide(nil)
          pick.try_decide(value)
          matched = true
        else
          @recv_q << offer
        end
      end
      -> { @mtx.synchronize { @recv_q.delete(offer) rescue nil } }
    end
  end

  class SendEvt(T) < Event(Nil)
    def initialize(@ch : Chan(T), @val : T); end

    def try_register(pick : Pick(Nil)) : Proc(Nil)
      @ch.register_send(@val, pick)
    end
  end

  class RecvEvt(T) < Event(T)
    def initialize(@ch : Chan(T)); end

    def try_register(pick : Pick(T)) : Proc(Nil)
      @ch.register_recv(pick)
    end
  end

  # -----------------------
  # timeout_evt
  # -----------------------
  class TimeoutEvt < Event(Symbol)
    def initialize(@duration : Time::Span); end

    def try_register(pick : Pick(Symbol)) : Proc(Nil)
      cancelled = Atomic(Bool).new(false)
      spawn do
        sleep @duration
        unless cancelled.get
          pick.try_decide(:timeout)
        end
      end
      -> { cancelled.set(true) }
    end
  end

  # -----------------------
  # wrap_evt
  # -----------------------
  class WrapEvt(A, B) < Event(B)
    def initialize(@inner : Event(A), &@f : A -> B); end

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
  end

  # -----------------------
  # guard_evt
  # -----------------------
  class GuardEvt(T) < Event(T)
    @block : Proc(Event(T))

    def initialize(&block : -> E) forall E
      @block = -> { block.call.as(Event(T)) }
    end

    def try_register(pick : Pick(T)) : Proc(Nil)
      evt = @block.call
      evt.try_register(pick)
    end
  end

  # -----------------------
  # nack_evt
  # -----------------------
  # -----------------------
  # nack_evt (fixed)
  # -----------------------
  class NackEvt(T) < Event(T)
    def initialize(@inner : Event(T), &@on_cancel : -> Nil); end

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
  # choose_evt
  # -----------------------
  class ChooseEvt(T) < Event(T)
    def initialize(@evts : Array(Event(T))); end

    def try_register(pick : Pick(T)) : Proc(Nil)
      cancels = @evts.map(&.try_register(pick))
      spawn do
        pick.wait
        cancels.each &.call
      end
      -> { cancels.each &.call }
    end
  end

  # -----------------------
  # Public API
  # -----------------------
  def self.sync(evt : Event(T)) : T forall T
    pick = Pick(T).new
    cancel = evt.try_register(pick)
    pick.wait
    cancel.call
    pick.value
  end

  def self.always(x : T) : Event(T) forall T
    AlwaysEvt(T).new(x)
  end

  def self.never : Event(T) forall T
    NeverEvt(T).new
  end

  def self.timeout(duration : Time::Span) : Event(Symbol)
    TimeoutEvt.new(duration)
  end

  def self.wrap(evt : Event(A), &block : A -> B) : Event(B) forall A, B
    WrapEvt(A, B).new(evt, &block)
  end

  def self.guard(&block : -> Event(T)) : Event(T) forall T
    GuardEvt(T).new(&block)
  end

  def self.nack(evt : Event(T), &block : -> Nil) : Event(T) forall T
    NackEvt(T).new(evt, &block)
  end

  def self.choose(evts : Array(Event(T))) : Event(T) forall T
    flat = evts.flat_map { |e| e.is_a?(ChooseEvt(T)) ? e.@evts : [e] }
    ChooseEvt(T).new(flat)
  end
end