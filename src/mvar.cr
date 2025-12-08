# src/mvar.cr
# ---------------------------------------------------------------------
# MVar - mutable synchronization variable (M-structure).
#
# Conceptually, an MVar is a channel of capacity 1:
# - put blocks if full
# - take blocks if empty
# - read returns the value without removing it
#
# SML API (SYNC_VAR signature):
#   val mVar      : unit -> 'a mvar
#   val mVarInit  : 'a -> 'a mvar
#   val mPut      : ('a mvar * 'a) -> unit
#   val mTake     : 'a mvar -> 'a
#   val mTakeEvt  : 'a mvar -> 'a event
#   val mTakePoll : 'a mvar -> 'a option
#   val mGet      : 'a mvar -> 'a
#   val mGetEvt   : 'a mvar -> 'a event
#   val mGetPoll  : 'a mvar -> 'a option
#   val mSwap     : ('a mvar * 'a) -> 'a
#   val mSwapEvt  : ('a mvar * 'a) -> 'a event
#   val sameMVar  : ('a mvar * 'a mvar) -> bool
# ---------------------------------------------------------------------

# required by src/cml.cr

module CML
  class MVar(T)
    @value : T? = nil
    @put_queue = Deque({T, Pick(Nil)}).new
    @takers = Deque(Pick(T)).new
    @readers = Deque(Pick(T)).new
    @mtx = Mutex.new
    # Hash-based lookup for O(1) cancellation
    @put_lookup = Hash(Pick(Nil), {T, Pick(Nil)}).new
    @take_lookup = Hash(Pick(T), Pick(T)).new
    @read_lookup = Hash(Pick(T), Pick(T)).new

    # Create an empty MVar
    # Equivalent to SML's: val mVar : unit -> 'a mvar
    def initialize
    end

    # Create an MVar initialized with a value
    # Equivalent to SML's: val mVarInit : 'a -> 'a mvar
    def initialize(initial_value : T)
      @value = initial_value
    end

    # -----------------------
    # Modern SML API (snake_case methods)
    # -----------------------

    # Put a value into the MVar (blocks if full)
    # Equivalent to SML's: val mPut : 'a mvar * 'a -> unit
    def m_put(value : T)
      CML.sync(m_take_evt.as(Event(Nil))) rescue nil # Wait if full first
      CML.sync(put_evt(value))
    end

    # Take the value from the MVar (blocks if empty)
    # Equivalent to SML's: val mTake : 'a mvar -> 'a
    def m_take : T
      CML.sync(m_take_evt)
    end

    # Event for taking a value from the MVar
    # Equivalent to SML's: val mTakeEvt : 'a mvar -> 'a event
    def m_take_evt : Event(T)
      TakeEvt(T).new(self)
    end

    # Non-blocking take poll
    # Equivalent to SML's: val mTakePoll : 'a mvar -> 'a option
    def m_take_poll : T?
      take_poll
    end

    # Read the value without removing it (blocks if empty)
    # Equivalent to SML's: val mGet : 'a mvar -> 'a
    def m_get : T
      CML.sync(m_get_evt)
    end

    # Event for reading a value from the MVar
    # Equivalent to SML's: val mGetEvt : 'a mvar -> 'a event
    def m_get_evt : Event(T)
      ReadEvt(T).new(self)
    end

    # Non-blocking get poll
    # Equivalent to SML's: val mGetPoll : 'a mvar -> 'a option
    def m_get_poll : T?
      get_poll
    end

    # Swap the value atomically (blocks if empty)
    # Equivalent to SML's: val mSwap : 'a mvar * 'a -> 'a
    def m_swap(new_value : T) : T
      CML.sync(m_swap_evt(new_value))
    end

    # Event for swapping the value atomically
    # Equivalent to SML's: val mSwapEvt : 'a mvar * 'a -> 'a event
    def m_swap_evt(new_value : T) : Event(T)
      # Swap is: take old value, put new value, return old value
      # Using wrap to ensure the put happens after take completes
      CML.wrap(m_take_evt) do |old_value|
        # After taking, put the new value
        # This uses the internal put since we just emptied the slot
        @mtx.synchronize do
          @value = new_value
          # Wake any readers with the new value
          readers = @readers.to_a
          @readers.clear
          @read_lookup.clear
          readers.each(&.try_decide(new_value))
        end
        old_value
      end
    end

    # Check if two MVars are the same
    # Equivalent to SML's: val sameMVar : ('a mvar * 'a mvar) -> bool
    def same?(other : MVar(T)) : Bool
      object_id == other.object_id
    end

    # -----------------------
    # Legacy API (aliases)
    # -----------------------

    # Put a value into the MVar (blocks if full)
    def put(value : T)
      CML.sync(put_evt(value))
    end

    # Take the value from the MVar (blocks if empty)
    def take : T
      m_take
    end

    # Read the value without removing it (blocks if empty)
    def get : T
      m_get
    end

    # Swap the value atomically (blocks if empty)
    def swap(new_value : T) : T
      m_swap(new_value)
    end

    # Try to take without blocking
    def take_poll : T?
      @mtx.synchronize do
        if val = @value
          @value = nil
          val
        end
      end
    end

    # Try to get without blocking
    def get_poll : T?
      @value
    end

    # -----------------------
    # Event constructors
    # -----------------------

    # Event that puts a value if the MVar is empty.
    def put_evt(value : T) : Event(Nil)
      PutEvt(T).new(self, value)
    end

    # Event that takes a value if present.
    def take_evt : Event(T)
      TakeEvt(T).new(self)
    end

    # Event that reads a value without removing it.
    def read_evt : Event(T)
      ReadEvt(T).new(self)
    end

    # Event that swaps the current value with a new one
    # Equivalent to SML's: val mSwapEvt : 'a mvar * 'a -> 'a event
    def swap_evt(new_value : T) : Event(T)
      m_swap_evt(new_value)
    end

    # Internal registration helpers to avoid accessing ivars from nested classes.
    def register_put(value : T, pick : Pick(Nil)) : Proc(Nil)
      @mtx.synchronize do
        if @value.nil?
          # Try direct handoff to a waiting taker
          loop do
            taker = @takers.shift?
            break unless taker
            @take_lookup.delete(taker)
            if taker.try_decide(value)
              pick.try_decide(nil)
              return -> { }
            end
          end
          # No taker committed; try to commit this put by filling the slot
          if pick.try_decide(nil)
            @value = value
            # Wake all waiting readers (they don't consume)
            readers = @readers
            @readers = Deque(Pick(T)).new
            @read_lookup.clear
            readers.each(&.try_decide(value))
          end
          return -> { }
        else
          # Full: enqueue this put until a taker makes room
          entry = {value, pick}
          @put_queue << entry
          @put_lookup[pick] = entry
          return -> { @mtx.synchronize { @put_lookup.delete(pick); @put_queue.delete(entry) rescue nil } }
        end
      end
    end

    def register_take(pick : Pick(T)) : Proc(Nil)
      @mtx.synchronize do
        if val = @value
          # Try to commit this take
          if pick.try_decide(val)
            # Empty the slot
            @value = nil
            # If there is a pending put, immediately fill slot with it
            if entry = @put_queue.shift?
              v2, put_pick = entry
              @put_lookup.delete(put_pick)
              @value = v2
              put_pick.try_decide(nil)
              # Wake all readers for the new value
              readers = @readers
              @readers = Deque(Pick(T)).new
              @read_lookup.clear
              readers.each(&.try_decide(v2))
            end
          end
          return -> { }
        else
          # Empty: enqueue taker
          @takers << pick
          @take_lookup[pick] = pick
          return -> { @mtx.synchronize { @take_lookup.delete(pick); @takers.delete(pick) rescue nil } }
        end
      end
    end

    def register_read(pick : Pick(T)) : Proc(Nil)
      @mtx.synchronize do
        if val = @value
          pick.try_decide(val)
          return -> { }
        else
          @readers << pick
          @read_lookup[pick] = pick
          return -> { @mtx.synchronize { @read_lookup.delete(pick); @readers.delete(pick) rescue nil } }
        end
      end
    end

    # Event for putting a value into an MVar.
    #
    # Atomicity: Registration attempts to put the value atomically.
    # If the MVar is empty, the put succeeds immediately and the fiber continues.
    # If the MVar is full, the fiber blocks until a take operation makes space.
    #
    # Fiber Behavior: Blocks the fiber if the MVar is full, otherwise continues immediately.
    private class PutEvt(T) < Event(Nil)
      def initialize(@mvar : MVar(T), @value : T)
      end

      def try_register(pick : Pick(Nil)) : Proc(Nil)
        @mvar.register_put(@value, pick)
      end
    end

    # Event for taking a value from an MVar.
    #
    # Atomicity: Registration attempts to take the value atomically.
    # If the MVar is full, the take succeeds immediately and the fiber continues.
    # If the MVar is empty, the fiber blocks until a put operation provides a value.
    #
    # Fiber Behavior: Blocks the fiber if the MVar is empty, otherwise continues immediately.
    private class TakeEvt(T) < Event(T)
      def initialize(@mvar : MVar(T))
      end

      def try_register(pick : Pick(T)) : Proc(Nil)
        @mvar.register_take(pick)
      end
    end

    # Event for reading a value from an MVar without removing it.
    #
    # Atomicity: Registration attempts to read the value atomically.
    # If the MVar is full, the read succeeds immediately and the fiber continues.
    # If the MVar is empty, the fiber blocks until a put operation provides a value.
    #
    # Fiber Behavior: Blocks the fiber if the MVar is empty, otherwise continues immediately.
    # Unlike take, the value remains in the MVar after reading.
    private class ReadEvt(T) < Event(T)
      def initialize(@mvar : MVar(T))
      end

      def try_register(pick : Pick(T)) : Proc(Nil)
        @mvar.register_read(pick)
      end
    end

    # Event for atomically swapping the value in an MVar.
    #
    # Atomicity: Registration attempts to swap atomically.
  end

  # -----------------------
  # Module-level SML API functions
  # -----------------------

  # Create a new empty MVar.
  # Equivalent to SML's: val mVar : unit -> 'a mvar
  def self.m_var(type : T.class) : MVar(T) forall T
    MVar(T).new
  end

  # Create a new MVar initialized with a value.
  # Equivalent to SML's: val mVarInit : 'a -> 'a mvar
  def self.m_var_init(value : T) : MVar(T) forall T
    MVar(T).new(value)
  end

  # Put a value into an MVar.
  # Equivalent to SML's: val mPut : ('a mvar * 'a) -> unit
  def self.m_put(mvar : MVar(T), value : T) forall T
    mvar.m_put(value)
  end

  # Take a value from an MVar.
  # Equivalent to SML's: val mTake : 'a mvar -> 'a
  def self.m_take(mvar : MVar(T)) : T forall T
    mvar.m_take
  end

  # Event for taking a value from an MVar.
  # Equivalent to SML's: val mTakeEvt : 'a mvar -> 'a event
  def self.m_take_evt(mvar : MVar(T)) : Event(T) forall T
    mvar.m_take_evt
  end

  # Non-blocking take poll for an MVar.
  # Equivalent to SML's: val mTakePoll : 'a mvar -> 'a option
  def self.m_take_poll(mvar : MVar(T)) : T? forall T
    mvar.m_take_poll
  end

  # Get a value from an MVar (without removing).
  # Equivalent to SML's: val mGet : 'a mvar -> 'a
  def self.m_get(mvar : MVar(T)) : T forall T
    mvar.m_get
  end

  # Event for getting a value from an MVar.
  # Equivalent to SML's: val mGetEvt : 'a mvar -> 'a event
  def self.m_get_evt(mvar : MVar(T)) : Event(T) forall T
    mvar.m_get_evt
  end

  # Non-blocking get poll for an MVar.
  # Equivalent to SML's: val mGetPoll : 'a mvar -> 'a option
  def self.m_get_poll(mvar : MVar(T)) : T? forall T
    mvar.m_get_poll
  end

  # Swap a value in an MVar.
  # Equivalent to SML's: val mSwap : ('a mvar * 'a) -> 'a
  def self.m_swap(mvar : MVar(T), value : T) : T forall T
    mvar.m_swap(value)
  end

  # Event for swapping a value in an MVar.
  # Equivalent to SML's: val mSwapEvt : ('a mvar * 'a) -> 'a event
  def self.m_swap_evt(mvar : MVar(T), value : T) : Event(T) forall T
    mvar.m_swap_evt(value)
  end

  # Check if two MVars are the same.
  # Equivalent to SML's: val sameMVar : ('a mvar * 'a mvar) -> bool
  def self.same_m_var(mvar1 : MVar(T), mvar2 : MVar(T)) : Bool forall T
    mvar1.same?(mvar2)
  end
end