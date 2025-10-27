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
      WriteEvt.new(self, value)
    end

    # Fill the IVar once; subsequent attempts are ignored.
    def fill(value : T) : Nil
      ready = [] of Pick(T)
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

    # Event that fires once the IVar has a value.
    def read_evt : Event(T)
      ReadEvt.new(self)
    end

    # Internal event: when sync'ed, fills the ivar.
    private class WriteEvt < Event(Nil)
      def initialize(@ivar : IVar(T), @value : T); end

      def try_register(pick : Pick(Nil)) : Proc(Nil)
        @ivar.@mtx.synchronize do
          if @ivar.@value.nil?
            if pick.try_decide(nil)
              @ivar.@value = @value
              # Wake any waiting readers
              until @ivar.@reads.empty?
                r = @ivar.@reads.shift?
                r.try_decide(@value) if r
              end
            end
            return ->{}
          else
            raise "IVar already filled"
          end
        end
      end
    end

    # Internal event: when sync'ed, returns the value.
    private class ReadEvt < Event(T)
      def initialize(@ivar : IVar(T)); end

      def try_register(pick : Pick(T)) : Proc(Nil)
        @ivar.@mtx.synchronize do
          if val = @ivar.@value
            pick.try_decide(val)
            return ->{}
          else
            @ivar.@reads << pick
          end
        end
        -> { @ivar.@mtx.synchronize { @ivar.@reads.delete(pick) rescue nil } }
      end
    end
  end
end

