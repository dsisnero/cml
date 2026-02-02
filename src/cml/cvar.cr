module CML
  # Internal synchronization primitive used for nack semantics (matches SML/NJ cvar).
  class CVar
    alias State = Unset | Set

    # Unset state tracks waiting transactions
    class Unset
      property waiters = Array(TransactionId).new
    end

    # Set state (no waiters tracked once set)
    class Set
    end

    # Event for waiting on a CVar
    class Event < CML::Event(Nil)
      def initialize(@cvar : CVar)
      end

      def poll : EventStatus(Nil)
        @cvar.poll
      end

      protected def force_impl : EventGroup(Nil)
        BaseGroup(Nil).new(-> : EventStatus(Nil) { poll })
      end
    end

    @state : State
    @mtx = CML::Sync::Mutex.new

    def initialize
      @state = Unset.new
    end

    def set? : Bool
      @state.is_a?(Set)
    end

    # Set the cvar, waking all waiters
    def set!
      waiters = [] of TransactionId

      @mtx.synchronize do
        case s = @state
        when Unset
          waiters = s.waiters.dup
          @state = Set.new
        when Set
          # Already set, ignore
        end
      end

      # Resume all waiters outside the lock (commit them)
      waiters.each do |tid|
        next if tid.cancelled?
        tid.try_commit_and_resume
      end
    end

    # Wait for the cvar to be set (returns event status)
    def poll : EventStatus(Nil)
      @mtx.synchronize do
        case @state
        when Set
          Enabled(Nil).new(priority: -1, value: nil)
        else
          Blocked(Nil).new do |tid, next_fn|
            case s = @state
            when Unset
              s.waiters << tid
              next_fn.call
            when Set
              tid.resume_fiber
            end
          end
        end
      end
    end
  end
end
