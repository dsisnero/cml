# src/mvar.cr
# ---------------------------------------------------------------------
# MVar — mutable synchronization variable, like Haskell’s or Reppy’s version.
#
# Conceptually, an MVar is a channel of capacity 1:
# - put blocks if full
# - take blocks if empty
# - read returns the value without removing it
# ---------------------------------------------------------------------

require "./cml"

module CML
  class MVar(T)
    @value : T? = nil
    @putter : Tuple(T, Pick(Nil))? = nil
    @takers = Deque(Pick(T)).new
    @mtx = Mutex.new

    # Event that puts a value if the MVar is empty.
    def put_evt(value : T) : Event(Nil)
      PutEvt.new(self, value)
    end

    # Event that takes a value if present.
    def take_evt : Event(T)
      TakeEvt.new(self)
    end

    # Event that reads a value without removing it.
    def read_evt : Event(T)
      ReadEvt.new(self)
    end

    private class PutEvt < Event(Nil)
      def initialize(@mvar : MVar(T), @value : T); end

      def try_register(pick : Pick(Nil)) : Proc(Nil)
        cancel = ->{}
        matched = false
        @mvar.@mtx.synchronize do
          if @mvar.@value.nil?
            if taker = @mvar.@takers.shift?
              # A waiting taker: hand off directly
              taker.try_decide(@value)
              pick.try_decide(nil)
              matched = true
            else
              # store in slot
              @mvar.@value = @value
              @mvar.@putter = {@value, pick}
            end
          else
            # already full; do nothing until a taker clears
          end
        end
        cancel
      end
    end

    private class TakeEvt < Event(T)
      def initialize(@mvar : MVar(T)); end

      def try_register(pick : Pick(T)) : Proc(Nil)
        cancel = ->{}
        @mvar.@mtx.synchronize do
          if val = @mvar.@value
            pick.try_decide(val)
            @mvar.@value = nil
            if put = @mvar.@putter
              put[1].try_decide(nil)
              @mvar.@putter = nil
            end
          else
            @mvar.@takers << pick
          end
        end
        cancel
      end
    end

    private class ReadEvt < Event(T)
      def initialize(@mvar : MVar(T)); end

      def try_register(pick : Pick(T)) : Proc(Nil)
        cancel = ->{}
        @mvar.@mtx.synchronize do
          if val = @mvar.@value
            pick.try_decide(val)
          else
            @mvar.@takers << pick
          end
        end
        cancel
      end
    end
  end
end

