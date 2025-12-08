# src/cml/barrier.cr
#
# Port of SML/NJ CML barrier.sml to Crystal
# COPYRIGHT (c) 2011 The Fellowship of SML/NJ (http://www.smlnj.org)
# All rights reserved.
#
# A barrier is a synchronization primitive where a group of fibers
# wait until all enrolled fibers have reached the barrier point.
# When all fibers arrive, an update function is applied to the shared state
# and all fibers are released.
#
# SML signature:
#   structure Barrier :> BARRIER =
#     sig
#       type 'a barrier
#       type 'a enrollment
#
#       val barrier : ('a -> 'a) -> 'a -> 'a barrier
#       val enroll : 'a barrier -> 'a enrollment
#       val wait : 'a enrollment -> 'a
#       val resign : 'a enrollment -> unit
#       val value : 'a enrollment -> 'a
#     end

require "../cml"

module CML
  # Result type for barrier wait
  enum BarrierResult
    Success
    Failed
  end

  # Enrollment status
  enum EnrollmentStatus
    Enrolled
    Waiting
    Resigned
  end

  # A barrier with shared state of type T
  class Barrier(T)
    @state : T
    @update : Proc(T, T)
    @n_enrolled = Atomic(Int32).new(0)
    @n_waiting = Atomic(Int32).new(0)
    @waiting = Array(Channel(T | Exception)).new
    @mtx = Mutex.new

    # Create a new barrier.
    # The update function is applied to the global state when all enrolled
    # fibers have reached the barrier.
    #
    # Equivalent to SML's:
    #   val barrier : ('a -> 'a) -> 'a -> 'a barrier
    def initialize(@update : Proc(T, T), initial_state : T)
      @state = initial_state
    end

    # Get the current number of enrolled fibers
    def enrolled_count : Int32
      @n_enrolled.get
    end

    # Get the current number of waiting fibers
    def waiting_count : Int32
      @n_waiting.get
    end

    # Get the current barrier state (for internal use by enrollments)
    protected def state : T
      @state
    end

    # Enroll in this barrier
    # Equivalent to SML's: val enroll : 'a barrier -> 'a enrollment
    def enroll : Enrollment(T)
      @n_enrolled.add(1)
      Enrollment(T).new(self)
    end

    # Internal: wait at the barrier
    protected def do_wait(enrollment : Enrollment(T)) : T
      @mtx.synchronize do
        case enrollment.status
        when EnrollmentStatus::Enrolled
          enrollment.status = EnrollmentStatus::Waiting
          new_waiting = @n_waiting.add(1) + 1

          if new_waiting == @n_enrolled.get
            # All threads are at the barrier, proceed
            begin
              new_state = @update.call(@state)
              @state = new_state

              # Wake all waiting fibers with the new state
              @waiting.each do |ch|
                ch.send(new_state) rescue nil
              end
              @waiting.clear
              @n_waiting.set(0)

              # Reset all enrolled fibers back to ENROLLED status
              # (This happens automatically as we return)
              enrollment.status = EnrollmentStatus::Enrolled
              return new_state
            rescue ex
              # If update fails, propagate exception to all waiters
              @waiting.each do |ch|
                ch.send(ex) rescue nil
              end
              @waiting.clear
              @n_waiting.set(0)
              enrollment.status = EnrollmentStatus::Enrolled
              raise ex
            end
          else
            # Not all threads are here yet, wait
            ch = Channel(T | Exception).new(1)
            @waiting << ch
            enrollment.wait_channel = ch
          end
        when EnrollmentStatus::Waiting
          raise "Multiple barrier waits"
        when EnrollmentStatus::Resigned
          raise "Barrier wait after resignation"
        end
      end

      # Wait outside the lock
      if ch = enrollment.wait_channel
        result = ch.receive
        enrollment.status = EnrollmentStatus::Enrolled
        enrollment.wait_channel = nil
        case result
        when Exception
          raise result
        else
          result
        end
      else
        @state
      end
    end

    # Internal: resign from the barrier
    protected def do_resign(enrollment : Enrollment(T))
      @mtx.synchronize do
        case enrollment.status
        when EnrollmentStatus::Resigned
          # Ignore multiple resignations
        when EnrollmentStatus::Waiting
          raise "Cannot resign while waiting"
        when EnrollmentStatus::Enrolled
          enrollment.status = EnrollmentStatus::Resigned
          @n_enrolled.sub(1)
        end
      end
    end
  end

  # An enrollment in a barrier
  class Enrollment(T)
    property status : EnrollmentStatus = EnrollmentStatus::Enrolled
    property wait_channel : Channel(T | Exception)? = nil
    @barrier : Barrier(T)

    def initialize(@barrier : Barrier(T))
    end

    # Wait at the barrier until all enrolled fibers arrive.
    # Returns the updated state value.
    # Equivalent to SML's: val wait : 'a enrollment -> 'a
    def wait : T
      @barrier.do_wait(self)
    end

    # Resign from the barrier.
    # A resigned enrollment cannot wait anymore.
    # Equivalent to SML's: val resign : 'a enrollment -> unit
    def resign
      @barrier.do_resign(self)
    end

    # Get the current barrier state.
    # Equivalent to SML's: val value : 'a enrollment -> 'a
    def value : T
      @barrier.state
    end
  end

  # Module-level convenience functions

  # Create a new barrier with an update function and initial state
  def self.barrier(update : Proc(T, T), initial : T) : Barrier(T) forall T
    Barrier(T).new(update, initial)
  end

  # Create a simple counting barrier (state is the round number)
  def self.counting_barrier(initial_count : Int32 = 0) : Barrier(Int32)
    Barrier(Int32).new(->(x : Int32) { x + 1 }, initial_count)
  end
end