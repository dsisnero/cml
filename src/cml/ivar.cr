module CML
  # Write-once synchronization variable (SML/NJ compatible)
  class IVar(T)
    @value : Slot(T)
    @readers = Deque({Slot(T), AtomicFlag, TransactionId}).new
    @priority = 0
    @mtx = Mutex.new

    # Event used to wait for the value without leaking into the CML namespace.
    class GetEvent(U) < Event(U)
      @poll_fn : Proc(EventStatus(U))

      def initialize(@ivar : IVar(U))
        @poll_fn = @ivar.make_get_poll
      end

      def poll : EventStatus(U)
        @poll_fn.call
      end

      protected def force_impl : EventGroup(U)
        BaseGroup(U).new(@poll_fn)
      end
    end

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
      GetEvent(T).new(self)
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
end
