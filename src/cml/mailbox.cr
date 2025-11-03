# src/cml/mailbox.cr
# Asynchronous mailbox (unbounded, non-blocking send)
# Provides recv_evt for selective communication via CML events.

module CML
  class Mailbox(T)
    # Unbounded queue (FIFO)
    @queue = Deque(T).new
    @mtx = Mutex.new
    @recv_waiters = Deque(Pick(T)).new

    # Send a message asynchronously.
    # Never blocks, but may wake a waiting receiver.
    def send(value : T)
      recv_pick : Pick(T)? = nil

      @mtx.synchronize do
        if @recv_waiters.empty?
          @queue << value
        else
          recv_pick = @recv_waiters.shift?
        end
      end

      if recv_pick
        recv_pick.try_decide(value)
      end
      nil
    end

    # Receive a message synchronously (blocks until one available)
    def recv : T
      CML.sync(recv_evt)
    end

    # Reset the mailbox, clearing all queued messages and waiters.
    def reset
      @mtx.synchronize do
        @queue.clear
        @recv_waiters.clear
      end
    end

    # Non-blocking poll — returns nil if no messages are available.
    def poll : T?
      @mtx.synchronize { @queue.shift? }
    end

    # Event-based receive (for use in choose)
    def recv_evt : Event(T)
      RecvEvt(T).new(self)
    end

    protected def remove_waiter(pick : Pick(T))
      @mtx.synchronize { @recv_waiters.delete(pick) rescue nil }
      nil
    end

    # Internal event representing a mailbox receive operation.
    class RecvEvt(T) < Event(T)
      def initialize(@mb : Mailbox(T)); end

      def try_register(pick : Pick(T)) : Proc(Nil)
        value : T? = nil

        @mb.@mtx.synchronize do
          if val = @mb.@queue.shift?
            value = val
          else
            @mb.@recv_waiters << pick
          end
        end

        if value
          pick.try_decide(value)
          -> { }
        else
          -> { @mb.remove_waiter(pick); nil }
        end
      end

      def poll : T?
        @mb.@mtx.synchronize { @mb.@queue.first? }
      end
    end
  end
end
