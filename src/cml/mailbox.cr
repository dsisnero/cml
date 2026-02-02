module CML
  # Mailbox - Asynchronous Channel (SML/NJ compatible)
  # Unlike Chan, send is non-blocking (producer can always enqueue).
  # Receive blocks until a message is available. Fairness via priority.
  #
  # SML signature:
  #   val mailbox : unit -> 'a mbox
  #   val sameMailbox : ('a mbox * 'a mbox) -> bool
  #   val send : ('a mbox * 'a) -> unit
  #   val recv : 'a mbox -> 'a
  #   val recvEvt : 'a mbox -> 'a event
  #   val recvPoll : 'a mbox -> 'a option
  class Mailbox(T)
    # State: either empty (with waiting receivers) or non-empty (with queued messages)
    @messages = Deque(T).new
    @receivers = Deque({Slot(T), AtomicFlag, TransactionId}).new
    @priority = 0
    @mtx = CML::Sync::Mutex.new

    def initialize
    end

    # Non-blocking send - always succeeds immediately
    def send(value : T) : Nil
      receiver_to_notify : {Slot(T), AtomicFlag, TransactionId}? = nil

      @mtx.synchronize do
        while entry = @receivers.shift?
          recv_slot, recv_done, recv_tid = entry
          next if recv_tid.cancelled?

          recv_slot.set(value)
          recv_done.set(true)
          receiver_to_notify = entry
          break
        end

        @messages << value unless receiver_to_notify
      end

      if entry = receiver_to_notify
        _, _, recv_tid = entry
        recv_tid.resume_fiber
      end

      Fiber.yield
    end

    # Blocking receive
    def recv : T
      CML.sync(recv_evt)
    end

    # Receive event for use in choose/select
    def recv_evt : Event(T)
      RecvEvent(T).new(self)
    end

    # Non-blocking receive poll
    def recv_poll : T?
      @mtx.synchronize do
        @messages.shift?
      end
    end

    # Identity comparison
    def same?(other : Mailbox(T)) : Bool
      object_id == other.object_id
    end

    # Reset mailbox to initial state (clears pending messages and receivers)
    def reset : Nil
      @mtx.synchronize do
        @messages.clear
        @receivers.clear
        @priority = 0
      end
    end

    protected def make_recv_poll : Proc(EventStatus(T))
      mbox = self
      recv_slot = Slot(T).new
      recv_done = AtomicFlag.new

      -> : EventStatus(T) {
        if recv_done.get
          has_val, val = recv_slot.get_if_present
          if has_val
            return Enabled(T).new(priority: 0, value: val.as(T))
          end
        end

        mbox.@mtx.synchronize do
          if msg = mbox.@messages.shift?
            recv_slot.set(msg)
            recv_done.set(true)
            prio = mbox.bump_priority
            return Enabled(T).new(priority: prio, value: msg)
          end

          Blocked(T).new do |tid, next_fn|
            mbox.@receivers << {recv_slot, recv_done, tid}
            tid.set_cleanup -> { mbox.remove_receiver(tid.id) }
            next_fn.call
          end
        end
      }
    end

    protected def remove_receiver(tid_id : Int64)
      @mtx.synchronize { @receivers.reject! { |_, _, t| t.id == tid_id } }
    end

    protected def bump_priority : Int32
      old = @priority
      @priority = old + 1
      old
    end

    # Nested receive event to avoid leaking into CML namespace.
    class RecvEvent(U) < Event(U)
      @poll_fn : Proc(EventStatus(U))

      def initialize(@mbox : Mailbox(U))
        @poll_fn = @mbox.make_recv_poll
      end

      def poll : EventStatus(U)
        @poll_fn.call
      end

      protected def force_impl : EventGroup(U)
        BaseGroup(U).new(@poll_fn)
      end
    end
  end
end
