module CML
  # Mutable synchronization variable (SML/NJ compatible)
  class MVar(T)
    private enum WaitKind
      Take
      Get
      Swap
    end

    @value : T?
    @has_value = false
    # A waiting swap must retain its replacement value; representing it as a
    # take loses that value when an empty MVar is later filled.
    @readers = Deque({Slot(T), AtomicFlag, TransactionId, WaitKind, T?}).new
    @priority = 0
    @mtx = CML::Sync::Mutex.new(:reentrant)

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
      readers_to_notify = [] of {Slot(T), AtomicFlag, TransactionId, WaitKind, T?}

      @mtx.synchronize do
        if @has_value
          raise PutError.new
        end

        @value = value
        @has_value = true
        @priority = 1
        readers_to_notify = satisfy_waiters
      end

      readers_to_notify.each { |_, _, tid, _, _| tid.resume_fiber }
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
      object_id == other.object_id
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
            mvar.register_waiter(recv_slot, recv_done, tid, WaitKind::Take, nil)
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
            mvar.register_waiter(recv_slot, recv_done, tid, WaitKind::Get, nil)
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
            mvar.register_waiter(recv_slot, recv_done, tid, WaitKind::Swap, new_value)
            next_fn.call
          end
        end
      }
    end

    protected def remove_reader(tid_id : Int64)
      @mtx.synchronize { @readers.reject! { |_, _, t, _, _| t.id == tid_id } }
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

    # Register after the first poll has returned Blocked. A concurrent put may
    # have made the value available in between, so admission must re-check and
    # satisfy the waiter while holding the same lock as mutation.
    protected def register_waiter(recv_slot : Slot(T), recv_done : AtomicFlag, tid : TransactionId, kind : WaitKind, replacement : T?) : Nil
      readers_to_notify = [] of {Slot(T), AtomicFlag, TransactionId, WaitKind, T?}

      @mtx.synchronize do
        if tid.active? && !recv_done.get
          @readers << {recv_slot, recv_done, tid, kind, replacement}
          tid.set_cleanup -> { remove_reader(tid.id) }
          readers_to_notify = satisfy_waiters if @has_value
        end
      end

      readers_to_notify.each { |_, _, waiter_tid, _, _| waiter_tid.resume_fiber }
    end

    # Consume queued operations in FIFO order. `get` observes but preserves the
    # value; `take` consumes it; `swap` returns it and installs its replacement.
    private def satisfy_waiters : Array({Slot(T), AtomicFlag, TransactionId, WaitKind, T?})
      ready = [] of {Slot(T), AtomicFlag, TransactionId, WaitKind, T?}

      while @has_value
        entry = @readers.shift?
        break unless entry
        recv_slot, recv_done, recv_tid, kind, replacement = entry
        next unless recv_tid.active?

        value = @value.as(T)
        recv_slot.set(value)
        recv_done.set(true)
        ready << entry

        case kind
        when WaitKind::Get
          # Keep serving getters while a value remains.
        when WaitKind::Take
          clear_value
        when WaitKind::Swap
          set_value(replacement.as(T))
        end
      end

      ready
    end
  end
end
