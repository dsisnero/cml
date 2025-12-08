# src/cml/ivar.cr
# One-shot write synchronization variable (I-structure).
# Readers block until a single writer fills the cell.
# Value may be Nil.
#
# SML API (SYNC_VAR signature):
#   val iVar     : unit -> 'a ivar
#   val iPut     : ('a ivar * 'a) -> unit
#   val iGet     : 'a ivar -> 'a
#   val iGetEvt  : 'a ivar -> 'a event
#   val iGetPoll : 'a ivar -> 'a option
#   val sameIVar : ('a ivar * 'a ivar) -> bool

module CML
  # Exception raised when trying to put into an already-filled IVar
  class Put < Exception
    def initialize
      super("IVar already filled")
    end
  end

  class IVar(T)
    @filled = Atomic(Bool).new(false)
    @value : T? = nil
    @read_waiters = Deque(Pick(T)).new
    @mutex = Mutex.new

    def initialize
    end

    # -----------------------
    # Modern SML API
    # -----------------------

    # Put a value into the IVar. Raises Put if already filled.
    # Equivalent to SML's: val iPut : ('a ivar * 'a) -> unit
    def i_put(x : T)
      waiters_to_decide : Array(Pick(T))? = nil

      @mutex.synchronize do
        if @filled.compare_and_set(false, true)
          @value = x
          # Collect all waiting picks to decide outside the lock
          waiters_to_decide = @read_waiters.to_a
          @read_waiters.clear
        else
          raise Put.new
        end
      end

      # Decide all waiting picks outside the lock
      if waiters = waiters_to_decide
        waiters.each do |pick|
          pick.try_decide(x)
        end
      end
    end

    # Get the value from the IVar, blocking until filled.
    # Equivalent to SML's: val iGet : 'a ivar -> 'a
    def i_get : T
      # Use event-based blocking through CML.sync
      CML.sync(i_get_evt)
    end

    # Event for getting the value from the IVar.
    # Equivalent to SML's: val iGetEvt : 'a ivar -> 'a event
    def i_get_evt : Event(T)
      ReadEvt(T).new(self)
    end

    # Non-blocking poll for the value.
    # Equivalent to SML's: val iGetPoll : 'a ivar -> 'a option
    def i_get_poll : T?
      return nil unless @filled.get
      @value
    end

    # Check if two IVars are the same.
    # Equivalent to SML's: val sameIVar : ('a ivar * 'a ivar) -> bool
    def same?(other : IVar(T)) : Bool
      object_id == other.object_id
    end

    # -----------------------
    # Legacy API (aliases)
    # -----------------------

    # Event that writes a value to the IVar (only succeeds once)
    def write_evt(value : T) : Event(Nil)
      WriteEvt(T).new(self, value)
    end

    # Event that reads the value from the IVar (blocks until filled)
    def read_evt : Event(T)
      i_get_evt
    end

    # Fill the IVar. Only succeeds once. (Legacy name)
    def fill(x : T)
      i_put(x)
    end

    # Block until filled, return final value (Legacy name)
    def read : T
      i_get
    end

    def filled?
      @filled.get
    end

    # Internal registration methods for events
    def register_write(value : T, pick : Pick(Nil)) : Proc(Nil)
      waiters_to_decide : Array(Pick(T))? = nil
      success = false

      @mutex.synchronize do
        if @filled.get
          # Already filled - raise Put
          raise Put.new
        end

        if @filled.compare_and_set(false, true)
          @value = value
          success = true
          waiters_to_decide = @read_waiters.to_a
          @read_waiters.clear
        else
          # Race condition - another writer won
          raise Put.new
        end
      end

      if success
        # Decide the write pick
        pick.try_decide(nil)
        # Wake up all waiting readers
        if waiters = waiters_to_decide
          waiters.each do |read_pick|
            read_pick.try_decide(value)
          end
        end
      end

      -> { }
    end

    def register_read(pick : Pick(T)) : Proc(Nil)
      # Fast path: already filled
      if @filled.get
        value = @value
        {% if T == Nil %}
          pick.try_decide(nil)
        {% else %}
          pick.try_decide(value.not_nil!) if value
        {% end %}
        return -> { }
      end

      # Slow path: need to wait
      @mutex.synchronize do
        # Double-check after acquiring lock
        if @filled.get
          value = @value
          {% if T == Nil %}
            pick.try_decide(nil)
          {% else %}
            pick.try_decide(value.not_nil!) if value
          {% end %}
          return -> { }
        end

        # Add to waiters
        @read_waiters << pick
      end

      # Return cancellation proc
      -> {
        @mutex.synchronize { @read_waiters.delete(pick) rescue nil }
      }
    end
  end

  # Event for writing a value to an IVar.
  private class WriteEvt(T) < Event(Nil)
    def initialize(@ivar : IVar(T), @value : T)
    end

    def try_register(pick : Pick(Nil)) : Proc(Nil)
      @ivar.register_write(@value, pick)
    end
  end

  # Event for reading a value from an IVar.
  private class ReadEvt(T) < Event(T)
    def initialize(@ivar : IVar(T))
    end

    def try_register(pick : Pick(T)) : Proc(Nil)
      @ivar.register_read(pick)
    end
  end

  # -----------------------
  # Module-level SML API functions
  # -----------------------

  # Create a new IVar.
  # Equivalent to SML's: val iVar : unit -> 'a ivar
  def self.i_var(type : T.class) : IVar(T) forall T
    IVar(T).new
  end

  # Put a value into an IVar.
  # Equivalent to SML's: val iPut : ('a ivar * 'a) -> unit
  def self.i_put(ivar : IVar(T), value : T) forall T
    ivar.i_put(value)
  end

  # Get the value from an IVar.
  # Equivalent to SML's: val iGet : 'a ivar -> 'a
  def self.i_get(ivar : IVar(T)) : T forall T
    ivar.i_get
  end

  # Event for getting the value from an IVar.
  # Equivalent to SML's: val iGetEvt : 'a ivar -> 'a event
  def self.i_get_evt(ivar : IVar(T)) : Event(T) forall T
    ivar.i_get_evt
  end

  # Non-blocking poll for the IVar value.
  # Equivalent to SML's: val iGetPoll : 'a ivar -> 'a option
  def self.i_get_poll(ivar : IVar(T)) : T? forall T
    ivar.i_get_poll
  end

  # Check if two IVars are the same.
  # Equivalent to SML's: val sameIVar : ('a ivar * 'a ivar) -> bool
  def self.same_i_var(ivar1 : IVar(T), ivar2 : IVar(T)) : Bool forall T
    ivar1.same?(ivar2)
  end
end