# src/cml/mailbox.cr
# Final CML-correct, race-free mailbox.
# No reliance on Pick#cancel. Compatible with your CML runtime.

module CML
  class Mailbox(T)
    @queue = Deque(T).new
    @waiters = Deque(Pick(T)).new
    @mtx = Mutex.new

    # ---------------------------------------------------------
    # SEND
    # ---------------------------------------------------------
    def send(value : T)
      @mtx.synchronize do
        if @waiters.empty?
          # Normal fast path: enqueue
          @queue << value
        else
          # Immediate handoff: commit inside lock
          pick = @waiters.shift
          pick.try_decide(value) # safe: shift → Pick(T)
        end
      end

      nil
    end

    # ---------------------------------------------------------
    # SYNC RECV
    # ---------------------------------------------------------
    def recv : T
      CML.sync(recv_evt)
    end

    # ---------------------------------------------------------
    # POLL (non-destructive)
    # ---------------------------------------------------------
    def poll : T?
      @mtx.synchronize { @queue.first? }
    end

    # ---------------------------------------------------------
    # DESTRUCTIVE TRY-RECV (optional)
    # ---------------------------------------------------------
    def try_recv_now : T?
      @mtx.synchronize { @queue.shift? }
    end

    # ---------------------------------------------------------
    # EVENT CONSTRUCTOR
    # ---------------------------------------------------------
    def recv_evt : Event(T)
      RecvEvt(T).new(self)
    end

    # Remove a waiter by identity
    protected def remove_waiter(target : Pick(T))
      @mtx.synchronize do
        new_q = Deque(Pick(T)).new
        @waiters.each do |p|
          new_q << p unless p.same?(target)
        end
        @waiters = new_q
      end
      nil
    end

    # ---------------------------------------------------------
    # INTERNAL EVENT
    # ---------------------------------------------------------
    # Event for receiving a message from a mailbox.
    #
    # Atomicity: Registration attempts to receive a message atomically.
    # If the mailbox has messages, the receive succeeds immediately and the fiber continues.
    # If the mailbox is empty, the fiber blocks until a send operation provides a message.
    #
    # Fiber Behavior: Blocks the fiber if the mailbox is empty, otherwise continues immediately.
    # Uses a mutex to ensure thread-safe access to the message queue and waiters list.
    class RecvEvt(T) < Event(T)
      def initialize(@mb : Mailbox(T))
      end

      def try_register(pick : Pick(T)) : Proc(Nil)
        @mb.@mtx.synchronize do
          if val = @mb.@queue.shift?
            # Immediate commit
            pick.try_decide(val)
            return -> { }
          else
            # No message, register waiter
            @mb.@waiters << pick
            return -> { @mb.remove_waiter(pick) }
          end
        end
      end

      def poll : T?
        @mb.@mtx.synchronize { @mb.@queue.first? }
      end
    end
  end
end
