# src/ivar.cr
# ---------------------------------------------------------------------
# Immutable single-assignment variable (IVar) — per Reppy's CML semantics.
#
# An IVar starts empty, can be filled exactly once, and read many times.
# Reading from an empty IVar blocks (as an Event) until a value is written.
# ---------------------------------------------------------------------

require "./cml"

module CML
  class IVar(T)
    @value : T?
    @reads = Deque(Pick(T)).new
    @mtx = Mutex.new

    def initialize
      @value = nil
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

    # Internal event: when sync'ed, returns the value.
    private class ReadEvt < Event(T)
      def initialize(@ivar : IVar(T)); end

      def try_register(pick : Pick(T)) : Proc(Nil)
        cancel = ->{}
        matched = false
        @ivar.@mtx.synchronize do
          if val = @ivar.@value
            pick.try_decide(val)
            matched = true
          else
            @ivar.@reads << pick
          end
        end
        cancel
      end
    end
  end
end

