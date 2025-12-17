module CML
  # Mutable synchronization variable (SML/NJ compatible)
  class MVar(T)
    @value : T?
    @has_value = false
    @readers = Deque({Slot(T), AtomicFlag, TransactionId, Bool}).new # Bool = is_take?
    @priority = 0
    @mtx = Mutex.new

    # Events are nested to avoid polluting the CML namespace.
    class TakeEvent(U) < Event(U)
      @poll_fn : Proc(EventStatus(U))

      def initialize(@mvar : MVar(U))
        @poll_fn = @mvar.make_take_poll
      end

      def poll : EventStatus(U)
        @poll_fn.call
      end

      protected def force_impl : EventGroup(U)
        BaseGroup(U).new(@poll_fn)
      end
    end

    class GetEvent(U) < Event(U)
      @poll_fn : Proc(EventStatus(U))

      def initialize(@mvar : MVar(U))
        @poll_fn = @mvar.make_get_poll
      end

      def poll : EventStatus(U)
        @poll_fn.call
      end

      protected def force_impl : EventGroup(U)
        BaseGroup(U).new(@poll_fn)
      end
    end

    class SwapEvent(U) < Event(U)
      @poll_fn : Proc(EventStatus(U))
      @new_value : U

      def initialize(@mvar : MVar(U), @new_value : U)
        @poll_fn = @mvar.make_swap_poll(@new_value)
      end

      def poll : EventStatus(U)
        @poll_fn.call
      end

      protected def force_impl : EventGroup(U)
        BaseGroup(U).new(@poll_fn)
      end
    end

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
      TakeEvent(T).new(self)
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
      GetEvent(T).new(self)
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
      SwapEvent(T).new(self, new_value)
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
end
