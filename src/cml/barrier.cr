require "../cml"

module CML
  class Barrier(T)
    # The current global state of the barrier
    @state : T

    # The function to update the state upon synchronization
    @update_proc : Proc(T, T)

    # Counters with explicit Int32 types to prevent inference errors
    @n_enrolled : Int32 = 0
    @n_waiting : Int32 = 0

    # Queue of waiting picks (CML rendezvous points)
    @waiters = Deque(Pick(T)).new

    @mtx = Mutex.new

    # Constructor 1: Block-based (Crystal style)
    # Usage: CML::Barrier(Int32).new(0) { |x| x + 1 }
    def initialize(initial_state : T, &block : T -> T)
      @state = initial_state
      @update_proc = block
    end

    # Constructor 2: Proc-based (Legacy/SML style)
    # Usage: CML::Barrier(Int32).new( ->(x: Int32){ x+1 }, 0 )
    def initialize(@update_proc : Proc(T, T), initial_state : T)
      @state = initial_state
    end

    # Public accessor for testing and metrics
    def enrolled_count : Int32
      @n_enrolled
    end

    # Public accessor for testing and metrics
    def waiting_count : Int32
      @n_waiting
    end

    # Equivalent to SML's: val enroll : 'a barrier -> 'a enrollment
    def enroll : Enrollment(T)
      @mtx.synchronize do
        @n_enrolled += 1
      end
      Enrollment(T).new(self)
    end

    # --- Internal Logic for Events ---

    # Called by the Event when a fiber attempts to sync
    protected def register_wait(enrollment : Enrollment(T), pick : Pick(T)) : Proc(Nil)
      trigger_now = false
      result_to_broadcast : T? = nil
      waiters_snapshot : Deque(Pick(T))? = nil

      @mtx.synchronize do
        # Validation
        if enrollment.status.resigned?
          raise "Barrier wait after resignation"
        elsif enrollment.status.waiting?
          raise "Multiple barrier waits"
        end

        enrollment.status = Enrollment::Status::Waiting
        @n_waiting += 1

        if @n_waiting == @n_enrolled
          # === TRIGGER BARRIER ===
          trigger_now = true

          # 1. Update State
          # Note: If this raises, it crashes the triggering fiber.
          @state = @update_proc.call(@state)
          result_to_broadcast = @state

          # 2. Grab all waiters to notify outside lock
          waiters_snapshot = @waiters
          @waiters = Deque(Pick(T)).new
          @n_waiting = 0

          # 3. Reset triggerer status
          enrollment.status = Enrollment::Status::Enrolled
        else
          # === QUEUE WAIT ===
          @waiters << pick
        end
      end

      # Perform notifications outside the lock
      if trigger_now
        if val = result_to_broadcast
          # Notify others
          waiters_snapshot.try do |list|
            list.each do |item|
              item.try_decide(val)
            end
          end

          # Notify self (the triggerer)
          pick.try_decide(val)

          return -> { }
        end
      end

      # Cancellation Proc (if user does CML.choose and times out)
      -> {
        @mtx.synchronize do
          # Attempt to remove this specific pick from the queue
          if @waiters.delete(pick)
            @n_waiting -= 1
            enrollment.status = Enrollment::Status::Enrolled
          end
        end
      }
    end

    # Internal: Logic to handle a resignation
    protected def do_resign(enrollment : Enrollment(T))
      trigger_needed = false
      final_result : T? = nil
      waiters_to_notify : Deque(Pick(T))? = nil

      @mtx.synchronize do
        return if enrollment.status.resigned?
        raise "Cannot resign while waiting" if enrollment.status.waiting?

        # Mark as resigned
        enrollment.status = Enrollment::Status::Resigned
        @n_enrolled -= 1

        # Check if resignation triggers the barrier for remaining waiters
        if @n_waiting > 0 && @n_waiting >= @n_enrolled
          trigger_needed = true
          @state = @update_proc.call(@state)
          final_result = @state

          waiters_to_notify = @waiters
          @waiters = Deque(Pick(T)).new
          @n_waiting = 0
        end
      end

      if trigger_needed && (res = final_result)
        waiters_to_notify.try &.each do |pick|
          pick.try_decide(res)
        end
      end
    end

    # --- Event Class ---

    private class BarrierWaitEvt(T) < Event(T)
      def initialize(@barrier : Barrier(T), @enrollment : Enrollment(T))
      end

      def try_register(pick : Pick(T)) : Proc(Nil)
        @barrier.register_wait(@enrollment, pick)
      end
    end

    # --- Enrollment Class ---

    class Enrollment(T)
      enum Status
        Enrolled
        Waiting
        Resigned
      end

      property status : Status = Status::Enrolled

      def initialize(@barrier : Barrier(T))
      end

      # Equivalent to SML's: val wait : 'a enrollment -> 'a
      # Blocks until the barrier triggers.
      def wait : T
        CML.sync(wait_evt)
      end

      # CML Extension: Returns an Event that can be used in CML.choose/select
      def wait_evt : Event(T)
        BarrierWaitEvt(T).new(@barrier, self)
      end

      # Equivalent to SML's: val resign : 'a enrollment -> unit
      def resign
        @barrier.do_resign(self)
      end

      # Equivalent to SML's: val value : 'a enrollment -> 'a
      def value : T
        @barrier.@state
      end
    end
  end

  # Helpers
  def self.barrier(update : Proc(T, T), initial : T) : Barrier(T) forall T
    Barrier(T).new(update, initial)
  end

  def self.counting_barrier(initial_count : Int32 = 0) : Barrier(Int32)
    Barrier(Int32).new(initial_count) { |x| x + 1 }
  end
end
