# One-Shot Channel — single-use optimized channel
#
# Based on Reppy & Xiao "Toward Optimization of Concurrent ML":
# channels used for exactly one send can use a simpler implementation
# with no queuing, no fairness tracking, and no cleanup registration.
#
# Pattern: used by rpc_client and other single-use rendezvous.
#
# Simplifications vs standard Chan:
#   - Single-valued "queues" instead of Deque allocations
#   - No TransactionId cleanup (at most one entry; cancel unused)
#   - No priority-based fairness (single sender + single receiver)
#   - No close/reset (single use)
#   - No poll loop (single entry, no need to `while shift?`)

module CML
  # A channel that supports exactly one send/receive pair.
  # After the first rendezvous, subsequent sends/recvs may behave unexpectedly.
  class OnceChan(T)
    # Internal state — use getter/setter instead of direct ivar access
    property send_entry : {T, AtomicFlag, TransactionId}?
    property recv_entry : {Slot(T), AtomicFlag, TransactionId}?
    @mtx = Sync::Mutex.new

    def send_evt(value : T) : Event(Nil)
      OnceSendEvent(T).new(self, value)
    end

    def recv_evt : Event(T)
      OnceRecvEvent(T).new(self)
    end

    def send(value : T) : Nil
      CML.sync(send_evt(value))
    end

    def recv : T
      CML.sync(recv_evt)
    end

    protected def make_send_poll(value : T) : Proc(EventStatus(Nil))
      chan = self
      send_done = AtomicFlag.new

      -> : EventStatus(Nil) {
        chan.@mtx.synchronize do
          if send_done.get
            return Enabled(Nil).new(priority: 0, value: nil)
          end

          # Check for waiting receiver
          if entry = chan.recv_entry
            recv_slot, recv_done, recv_tid = entry
            if recv_tid.active?
              recv_slot.set(value)
              recv_done.set(true)
              send_done.set(true)
              recv_tid.resume_fiber
              return Enabled(Nil).new(priority: 0, value: nil)
            end
          end

          # No receiver — store send entry and block
          Blocked(Nil).new do |tid, next_fn|
            chan.send_entry = {value, send_done, tid}
            next_fn.call
          end
        end
      }
    end

    protected def make_recv_poll : {Proc(EventStatus(T)), Slot(T)}
      chan = self
      recv_slot = Slot(T).new
      recv_done = AtomicFlag.new

      poll_fn = -> : EventStatus(T) {
        chan.@mtx.synchronize do
          if recv_done.get
            has_val, val = recv_slot.get_if_present
            if has_val
              return Enabled(T).new(priority: 0, value: val.as(T))
            end
          end

          # Check for waiting sender
          if entry = chan.send_entry
            send_value, send_done, send_tid = entry
            if send_tid.active?
              recv_slot.set(send_value)
              recv_done.set(true)
              send_done.set(true)
              send_tid.resume_fiber
              return Enabled(T).new(priority: 0, value: send_value)
            end
          end

          # No sender — store recv entry and block
          Blocked(T).new do |tid, next_fn|
            chan.recv_entry = {recv_slot, recv_done, tid}
            next_fn.call
          end
        end
      }

      {poll_fn, recv_slot}
    end
  end

  private class OnceSendEvent(T) < Event(Nil)
    @poll_fn : Proc(EventStatus(Nil))

    def initialize(@chan : OnceChan(T), value : T)
      @poll_fn = @chan.make_send_poll(value)
    end

    def poll : EventStatus(Nil)
      @poll_fn.call
    end

    protected def force_impl : EventGroup(Nil)
      BaseGroup(Nil).new(@poll_fn)
    end
  end

  private class OnceRecvEvent(T) < Event(T)
    @poll_fn : Proc(EventStatus(T))

    def initialize(@chan : OnceChan(T))
      @poll_fn, _ = @chan.make_recv_poll
    end

    def poll : EventStatus(T)
      @poll_fn.call
    end

    protected def force_impl : EventGroup(T)
      BaseGroup(T).new(@poll_fn)
    end
  end
end
