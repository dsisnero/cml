# src/mvar.cr
# ---------------------------------------------------------------------
# MVar — mutable synchronization variable, like Haskell’s or Reppy’s version.
#
# Conceptually, an MVar is a channel of capacity 1:
# - put blocks if full
# - take blocks if empty
# - read returns the value without removing it
# ---------------------------------------------------------------------

# required by src/cml.cr

module CML
  class MVar(T)
    @value : T? = nil
    @put_queue = Deque({T, Pick(Nil)}).new
    @takers = Deque(Pick(T)).new
    @readers = Deque(Pick(T)).new
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
        # Non-blocking: either hand off to a taker, fill the slot atomically if empty,
        # or enqueue if currently full.
        @mvar.@mtx.synchronize do
          if @mvar.@value.nil?
            # Try direct handoff to a waiting taker
            loop do
              taker = @mvar.@takers.shift?
              break unless taker
              if taker.try_decide(@value)
                pick.try_decide(nil)
                return ->{}
              end
              # If taker was already cancelled, try next
            end
            # No taker committed; try to commit this put by filling the slot
            if pick.try_decide(nil)
              @mvar.@value = @value
              # Wake all waiting readers (they don't consume)
              readers = @mvar.@readers
              @mvar.@readers = Deque(Pick(T)).new
              readers.each { |r| r.try_decide(@value) }
            end
            return ->{}
          else
            # Full: enqueue this put until a taker makes room
            entry = {@value, pick}
            @mvar.@put_queue << entry
            return -> { @mvar.@mtx.synchronize { @mvar.@put_queue.delete(entry) rescue nil } }
          end
        end
      end
    end

    private class TakeEvt < Event(T)
      def initialize(@mvar : MVar(T)); end

      def try_register(pick : Pick(T)) : Proc(Nil)
        @mvar.@mtx.synchronize do
          if val = @mvar.@value
            # Try to commit this take
            if pick.try_decide(val)
              # Empty the slot
              @mvar.@value = nil
              # If there is a pending put, immediately fill slot with it
              if entry = @mvar.@put_queue.shift?
                v2, put_pick = entry
                @mvar.@value = v2
                put_pick.try_decide(nil)
                # Wake all readers for the new value
                readers = @mvar.@readers
                @mvar.@readers = Deque(Pick(T)).new
                readers.each { |r| r.try_decide(v2) }
              end
            end
            return ->{}
          else
            # Empty: enqueue taker
            @mvar.@takers << pick
            return -> { @mvar.@mtx.synchronize { @mvar.@takers.delete(pick) rescue nil } }
          end
        end
      end
    end

    private class ReadEvt < Event(T)
      def initialize(@mvar : MVar(T)); end

      def try_register(pick : Pick(T)) : Proc(Nil)
        @mvar.@mtx.synchronize do
          if val = @mvar.@value
            pick.try_decide(val)
            return ->{}
          else
            @mvar.@readers << pick
            return -> { @mvar.@mtx.synchronize { @mvar.@readers.delete(pick) rescue nil } }
          end
        end
      end
    end
  end
end

