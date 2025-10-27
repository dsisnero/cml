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
      PutEvt(T).new(self, value)
    end

    # Event that takes a value if present.
    def take_evt : Event(T)
      TakeEvt(T).new(self)
    end

    # Event that reads a value without removing it.
    def read_evt : Event(T)
      ReadEvt(T).new(self)
    end

    # Internal registration helpers to avoid accessing ivars from nested classes.
    def register_put(value : T, pick : Pick(Nil)) : Proc(Nil)
      @mtx.synchronize do
        if @value.nil?
          # Try direct handoff to a waiting taker
          loop do
            taker = @takers.shift?
            break unless taker
            if taker.try_decide(value)
              pick.try_decide(nil)
              return ->{}
            end
          end
          # No taker committed; try to commit this put by filling the slot
          if pick.try_decide(nil)
            @value = value
            # Wake all waiting readers (they don't consume)
            readers = @readers
            @readers = Deque(Pick(T)).new
            readers.each { |r| r.try_decide(value) }
          end
          return ->{}
        else
          # Full: enqueue this put until a taker makes room
          entry = {value, pick}
          @put_queue << entry
          return -> { @mtx.synchronize { @put_queue.delete(entry) rescue nil } }
        end
      end
    end

    def register_take(pick : Pick(T)) : Proc(Nil)
      @mtx.synchronize do
        if val = @value
          # Try to commit this take
          if pick.try_decide(val)
            # Empty the slot
            @value = nil
            # If there is a pending put, immediately fill slot with it
            if entry = @put_queue.shift?
              v2, put_pick = entry
              @value = v2
              put_pick.try_decide(nil)
              # Wake all readers for the new value
              readers = @readers
              @readers = Deque(Pick(T)).new
              readers.each { |r| r.try_decide(v2) }
            end
          end
          return ->{}
        else
          # Empty: enqueue taker
          @takers << pick
          return -> { @mtx.synchronize { @takers.delete(pick) rescue nil } }
        end
      end
    end

    def register_read(pick : Pick(T)) : Proc(Nil)
      @mtx.synchronize do
        if val = @value
          pick.try_decide(val)
          return ->{}
        else
          @readers << pick
          return -> { @mtx.synchronize { @readers.delete(pick) rescue nil } }
        end
      end
    end

    private class PutEvt(T) < Event(Nil)
      def initialize(@mvar : MVar(T), @value : T); end

      def try_register(pick : Pick(Nil)) : Proc(Nil)
        @mvar.register_put(@value, pick)
      end
    end

    private class TakeEvt(T) < Event(T)
      def initialize(@mvar : MVar(T)); end

      def try_register(pick : Pick(T)) : Proc(Nil)
        @mvar.register_take(pick)
      end
    end

    private class ReadEvt(T) < Event(T)
      def initialize(@mvar : MVar(T)); end

      def try_register(pick : Pick(T)) : Proc(Nil)
        @mvar.register_read(pick)
      end
    end
  end
end

