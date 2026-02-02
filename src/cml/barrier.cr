# Barrier synchronization for CML
#
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

module CML
  class Barrier(T)
    # Enrollment status enum (nested to avoid namespace pollution)
    private enum EnrollmentStatus
      Enrolled
      Waiting
      Resigned
    end

    # Barrier enrollment - a thread's enrollment in a barrier
    class Enrollment(T)
      @status : EnrollmentStatus = EnrollmentStatus::Enrolled
      @barrier : Barrier(T)

      def initialize(@barrier : Barrier(T))
      end

      # Status checks
      def enrolled? : Bool
        @status == EnrollmentStatus::Enrolled
      end

      def waiting? : Bool
        @status == EnrollmentStatus::Waiting
      end

      def resigned? : Bool
        @status == EnrollmentStatus::Resigned
      end

      # Status transitions (internal)
      protected def mark_enrolled
        @status = EnrollmentStatus::Enrolled
      end

      protected def mark_waiting
        @status = EnrollmentStatus::Waiting
      end

      protected def mark_resigned
        @status = EnrollmentStatus::Resigned
      end

      # Wait on the barrier (blocking)
      # SML: val wait : 'a enrollment -> 'a
      def wait : T
        CML.sync(wait_evt)
      end

      # Wait event for use in choose/select
      def wait_evt : Event(T)
        WaitEvent(T).new(@barrier, self)
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

    # Barrier wait event (nested to avoid namespace pollution)
    private class WaitEvent(T) < Event(T)
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

    @state : T
    @update_fn : Proc(T, T)
    @enrolled_count = 0
    @waiting_count = 0
    @waiters = Deque({Slot(T), AtomicFlag, TransactionId}).new
    @mtx = Sync::Mutex.new

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
