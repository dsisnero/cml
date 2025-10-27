# src/ivar.cr
# ---------------------------------------------------------------------
# Immutable single-assignment variable (IVar) — per Reppy's CML semantics.
#
# An IVar starts empty, can be filled exactly once, and read many times.
# Reading from an empty IVar blocks (as an Event) until a value is written.
# ---------------------------------------------------------------------

# required by src/cml.cr

module CML
  class IVar(T)
    @value : T?
    @reads = Deque(Pick(T)).new
    @mtx = Mutex.new

    def initialize
      @value = nil
    end

    # Creates an event that fills the IVar exactly once.
    # If already filled, syncing this event raises.
    def write_evt(value : T) : Event(Nil)
      WriteEvt(T).new(self, value)
    end

    # Fill the IVar once; subsequent attempts are ignored.
    def fill(value : T) : Nil
      @mtx.synchronize do
        if @value.nil?
          @value = value
          # Wake any waiting readers
          until @reads.empty?
            pick = @reads.shift?
            pick.try_decide(value) if pick
          end
        end
      end
    end

    # Internal helper used by WriteEvt: set value and wake readers.
    # Raises if already filled.
    def set_and_wake!(value : T) : Nil
      @mtx.synchronize do
        if @value.nil?
          @value = value
          until @reads.empty?
            if r = @reads.shift?
              r.try_decide(value)
            end
          end
        else
          raise "IVar already filled"
        end
      end
    end

    # Internal: register a read waiter or complete immediately.
    def register_read(pick : Pick(T)) : Proc(Nil)
      @mtx.synchronize do
        if val = @value
          pick.try_decide(val)
          return -> { }
        else
          @reads << pick
          return -> { @mtx.synchronize { @reads.delete(pick) rescue nil } }
        end
      end
    end

    # Event that fires once the IVar has a value.
    def read_evt : Event(T)
      ReadEvt(T).new(self)
    end

    # Internal event: when sync'ed, fills the ivar.
    private class WriteEvt(T) < Event(Nil)
      def initialize(@ivar : IVar(T), @value : T); end

      def try_register(pick : Pick(Nil)) : Proc(Nil)
        if pick.try_decide(nil)
          @ivar.set_and_wake!(@value)
        end
        -> { }
      end
    end

    # Internal event: when sync'ed, returns the value.
    private class ReadEvt(T) < Event(T)
      def initialize(@ivar : IVar(T)); end

      def try_register(pick : Pick(T)) : Proc(Nil)
        @ivar.register_read(pick)
      end
    end
  end
end
