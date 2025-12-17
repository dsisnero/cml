require "./spec_helper.cr"

describe CML do
  describe "always" do
    it "returns the value immediately" do
      result = CML.sync(CML.always(42))
      result.should eq(42)
    end

    it "works with different types" do
      CML.sync(CML.always("hello")).should eq("hello")
      CML.sync(CML.always(nil)).should be_nil
    end
  end

  describe "channel send/recv" do
    it "completes rendezvous between sender and receiver" do
      ch = CML::Chan(Int32).new
      result = 0

      spawn do
        ch.send(42)
      end

      result = ch.recv
      Fiber.yield # Let sender complete

      result.should eq(42)
    end

    it "works with event-based API" do
      ch = CML::Chan(String).new
      result = ""

      spawn do
        CML.sync(ch.send_evt("hello"))
      end

      result = CML.sync(ch.recv_evt)
      Fiber.yield

      result.should eq("hello")
    end

    it "blocks sender until receiver is ready" do
      ch = CML::Chan(Int32).new
      order = [] of Int32

      spawn do
        order << 1
        ch.send(42)
        order << 3
      end

      Fiber.yield # Let sender start
      order << 2
      ch.recv
      Fiber.yield # Let sender complete

      order.should eq([1, 2, 3])
    end

    it "blocks receiver until sender is ready" do
      ch = CML::Chan(Int32).new
      order = [] of Int32

      spawn do
        order << 1
        val = ch.recv
        order << 3
        val.should eq(42)
      end

      Fiber.yield # Let receiver start
      order << 2
      ch.send(42)
      Fiber.yield # Let receiver complete

      order.should eq([1, 2, 3])
    end
  end

  describe "wrap" do
    it "transforms the result of an event" do
      result = CML.sync(CML.wrap(CML.always(10)) { |x| x * 2 })
      result.should eq(20)
    end

    it "transforms channel receive results" do
      ch = CML::Chan(Int32).new

      spawn do
        ch.send(5)
      end

      result = CML.sync(CML.wrap(ch.recv_evt) { |x| "got #{x}" })
      Fiber.yield

      result.should eq("got 5")
    end
  end

  describe "guard" do
    it "defers event creation until sync" do
      counter = 0
      evt = CML.guard do
        counter += 1
        CML.always(counter)
      end

      counter.should eq(0)

      result1 = CML.sync(evt)
      result1.should eq(1)
      counter.should eq(1)

      result2 = CML.sync(evt)
      result2.should eq(2)
      counter.should eq(2)
    end
  end

  describe "choose" do
    it "returns the first available event" do
      ch1 = CML::Chan(String).new
      ch2 = CML::Chan(String).new

      spawn do
        ch2.send("second")
      end

      result = CML.sync(CML.choose(ch1.recv_evt, ch2.recv_evt))
      Fiber.yield

      result.should eq("second")
    end

    it "returns immediately available always event" do
      ch = CML::Chan(Int32).new
      evt = CML.choose(ch.recv_evt, CML.always(42))

      result = CML.sync(evt)
      result.should eq(42)
    end

    it "handles multiple senders to multiple receivers" do
      ch1 = CML::Chan(Int32).new
      ch2 = CML::Chan(Int32).new

      spawn do
        sleep 10.milliseconds
        ch1.send(1)
      end

      spawn do
        ch2.send(2)
      end

      result = CML.sync(CML.choose(ch1.recv_evt, ch2.recv_evt))
      Fiber.yield

      result.should eq(2) # ch2 sends immediately
    end
  end

  describe "select" do
    it "is equivalent to sync(choose(events))" do
      ch = CML::Chan(Int32).new

      spawn do
        ch.send(42)
      end

      result = CML.select([ch.recv_evt, CML.always(0)])
      Fiber.yield

      # Either result is valid depending on timing
      [0, 42].should contain(result)
    end

    it "works with multiple recv_evts from different channels" do
      # This tests the case where select is called with an array of recv_evts
      # from different channels - this was causing a type error where
      # EventGroup(T)+ was not matching BaseGroup(T)
      done_ch = CML::Chan(Nil).new
      shutdown_ch = CML::Chan(Nil).new

      spawn do
        sleep 10.milliseconds
        done_ch.send(nil)
      end

      result = CML.select([done_ch.recv_evt, shutdown_ch.recv_evt])
      result.should be_nil
    end

    it "works with select in a loop with multiple channels" do
      # Simulates the batch execution pattern from the error report
      done_ch = CML::Chan(Nil).new
      shutdown_ch = CML::Chan(Nil).new
      count = 0

      3.times do
        spawn do
          sleep (10 * (count + 1)).milliseconds
          done_ch.send(nil) rescue nil
        end
        count += 1
      end

      3.times do
        CML.select([done_ch.recv_evt, shutdown_ch.recv_evt])
        break if shutdown_ch.closed?
      end

      # If we got here without error, the test passed
      true.should be_true
    end
  end

  describe "timeout" do
    # Note: These tests pass individually but may fail when run in sequence
    # due to fiber scheduling interactions from previous tests
    it "fires after the specified duration" do
      start = Time.monotonic
      CML.sync(CML.timeout(50.milliseconds))
      elapsed = Time.monotonic - start

      elapsed.should be >= 50.milliseconds
      elapsed.should be < 200.milliseconds
    end

    it "can be used with choose to implement timeout" do
      ch = CML::Chan(Int32).new

      result = CML.sync(CML.choose(
        CML.wrap(ch.recv_evt) { |v| {:value, v} },
        CML.wrap(CML.timeout(50.milliseconds)) { {:timeout, 0} }
      ))

      result[0].should eq(:timeout)
    end
  end

  describe "with_nack" do
    it "fires nack when event loses in choose" do
      nack_fired = false
      ch = CML::Chan(Int32).new

      evt = CML.choose(
        CML.with_nack do |nack_evt|
          spawn do
            CML.sync(nack_evt)
            nack_fired = true
          end
          ch.recv_evt
        end,
        CML.always(42)
      )

      result = CML.sync(evt)
      Fiber.yield # Let nack handler run

      result.should eq(42)
      nack_fired.should be_true
    end

    it "does not fire nack when event wins" do
      nack_fired = false

      evt = CML.with_nack do |nack_evt|
        spawn do
          CML.sync(nack_evt)
          nack_fired = true
        end
        CML.always(42)
      end

      result = CML.sync(evt)
      Fiber.yield

      result.should eq(42)
      nack_fired.should be_false
    end
  end

  describe "TransactionId" do
    it "starts in active state" do
      tid = CML::TransactionId.new
      tid.active?.should be_true
      tid.cancelled?.should be_false
    end

    it "transitions to cancelled state" do
      tid = CML::TransactionId.new
      tid.try_cancel.should be_true
      tid.cancelled?.should be_true
      tid.active?.should be_false
    end

    it "cannot be cancelled twice" do
      tid = CML::TransactionId.new
      tid.try_cancel.should be_true
      tid.try_cancel.should be_false
    end

    it "runs cleanup on cancel" do
      cleanup_ran = false
      tid = CML::TransactionId.new
      tid.set_cleanup -> { cleanup_ran = true }
      tid.try_cancel
      cleanup_ran.should be_true
    end
  end

  describe "Mailbox" do
    it "allows non-blocking send" do
      mbox = CML::Mailbox(Int32).new

      # Send should not block even without receiver
      mbox.send(1)
      mbox.send(2)
      mbox.send(3)

      # Now receive should get them in order
      mbox.recv.should eq(1)
      mbox.recv.should eq(2)
      mbox.recv.should eq(3)
    end

    it "blocks receiver until message available" do
      mbox = CML::Mailbox(Int32).new
      result = 0

      spawn do
        sleep 10.milliseconds
        mbox.send(42)
      end

      result = mbox.recv
      result.should eq(42)
    end

    it "supports recv_poll for non-blocking receive" do
      mbox = CML::Mailbox(Int32).new

      mbox.recv_poll.should be_nil

      mbox.send(42)
      mbox.recv_poll.should eq(42)
      mbox.recv_poll.should be_nil
    end

    it "supports recv_evt for use in choose" do
      mbox1 = CML::Mailbox(Int32).new
      mbox2 = CML::Mailbox(Int32).new

      mbox2.send(42)

      result = CML.sync(CML.choose(mbox1.recv_evt, mbox2.recv_evt))
      result.should eq(42)
    end

    it "supports same? for identity comparison" do
      mbox1 = CML::Mailbox(Int32).new
      mbox2 = CML::Mailbox(Int32).new

      mbox1.same?(mbox1).should be_true
      mbox1.same?(mbox2).should be_false
    end
  end

  describe "IVar" do
    it "allows single write" do
      iv = CML::IVar(Int32).new
      iv.i_put(42)
      iv.i_get.should eq(42)
    end

    it "raises on second write" do
      iv = CML::IVar(Int32).new
      iv.i_put(42)

      expect_raises(CML::PutError) do
        iv.i_put(100)
      end
    end

    it "blocks reader until value is written" do
      iv = CML::IVar(Int32).new
      result = 0

      spawn do
        sleep 10.milliseconds
        iv.i_put(42)
      end

      result = iv.i_get
      result.should eq(42)
    end

    it "allows multiple readers" do
      iv = CML::IVar(Int32).new
      results = Channel(Int32).new(2)

      spawn do
        results.send(iv.i_get)
      end

      spawn do
        results.send(iv.i_get)
      end

      Fiber.yield
      iv.i_put(42)

      results.receive.should eq(42)
      results.receive.should eq(42)
    end

    it "supports i_get_poll for non-blocking read" do
      iv = CML::IVar(Int32).new

      iv.i_get_poll.should be_nil
      iv.i_put(42)
      iv.i_get_poll.should eq(42)
      iv.i_get_poll.should eq(42) # Still returns value (not consumed)
    end

    it "supports i_get_evt for use in choose" do
      iv1 = CML::IVar(Int32).new
      iv2 = CML::IVar(Int32).new

      iv2.i_put(42)

      result = CML.sync(CML.choose(iv1.i_get_evt, iv2.i_get_evt))
      result.should eq(42)
    end
  end

  describe "MVar" do
    it "supports put and take" do
      mv = CML::MVar(Int32).new
      mv.m_put(42)
      mv.m_take.should eq(42)

      # After take, MVar is empty
      mv.m_take_poll.should be_nil
    end

    it "raises on put when full" do
      mv = CML::MVar(Int32).new
      mv.m_put(42)

      expect_raises(CML::PutError) do
        mv.m_put(100)
      end
    end

    it "blocks taker until value available" do
      mv = CML::MVar(Int32).new
      result = 0

      spawn do
        sleep 10.milliseconds
        mv.m_put(42)
      end

      result = mv.m_take
      result.should eq(42)
    end

    it "supports get without consuming" do
      mv = CML::MVar(Int32).new
      mv.m_put(42)

      mv.m_get.should eq(42)
      mv.m_get.should eq(42) # Still there
      mv.m_take.should eq(42)
      mv.m_take_poll.should be_nil # Now empty
    end

    it "supports swap" do
      mv = CML::MVar(Int32).new
      mv.m_put(1)

      old = mv.m_swap(2)
      old.should eq(1)

      mv.m_get.should eq(2)
    end

    it "supports initialization with value" do
      mv = CML::MVar(Int32).new(42)
      mv.m_take.should eq(42)
    end

    it "supports m_take_evt for use in choose" do
      mv1 = CML::MVar(Int32).new
      mv2 = CML::MVar(Int32).new(42)

      result = CML.sync(CML.choose(mv1.m_take_evt, mv2.m_take_evt))
      result.should eq(42)
    end
  end

  describe "CVar" do
    it "starts unset" do
      cvar = CML::CVar.new
      cvar.set?.should be_false
    end

    it "becomes set after set!" do
      cvar = CML::CVar.new
      cvar.set!
      cvar.set?.should be_true
    end

    # This test is incomplete - skipping for now
    pending "can wait for set" do
      cvar = CML::CVar.new

      spawn do
        sleep 10.milliseconds
        cvar.set!
      end

      # Wait on the cvar using the poll mechanism
      # This is a simplified test
      sleep 20.milliseconds
      cvar.set?.should be_true
    end
  end

  # ===========================================================================
  # New Feature Tests
  # ===========================================================================

  describe "Channel additional features" do
    it "supports same? for identity comparison" do
      ch1 = CML::Chan(Int32).new
      ch2 = CML::Chan(Int32).new

      ch1.same?(ch1).should be_true
      ch1.same?(ch2).should be_false
      CML.same_channel(ch1, ch1).should be_true
      CML.same_channel(ch1, ch2).should be_false
    end

    it "supports send_poll for non-blocking send" do
      ch = CML::Chan(Int32).new

      # No receiver, should return false
      ch.send_poll(42).should be_false

      # Add a receiver
      result = 0
      spawn do
        result = ch.recv
      end
      Fiber.yield

      # Now send should succeed
      ch.send_poll(42).should be_true
      Fiber.yield
      result.should eq(42)
    end

    it "supports recv_poll for non-blocking receive" do
      ch = CML::Chan(Int32).new

      # No sender, should return nil
      ch.recv_poll.should be_nil

      # Add a sender
      spawn do
        ch.send(42)
      end
      Fiber.yield

      # Now recv should succeed
      ch.recv_poll.should eq(42)
    end
  end

  describe "wrapHandler" do
    it "catches exceptions from guard during force" do
      evt = CML.guard do
        raise "Test error"
        CML.always(0)
      end

      wrapped = CML.wrap_handler(evt) do |ex|
        -1
      end

      result = CML.sync(wrapped)
      result.should eq(-1)
    end

    it "passes through normal values" do
      evt = CML.always(42)
      wrapped = CML.wrap_handler(evt) { |_| -1 }

      result = CML.sync(wrapped)
      result.should eq(42)
    end
  end

  describe "atTimeEvt" do
    it "fires at an absolute time" do
      target = Time.utc + 50.milliseconds
      start = Time.monotonic

      CML.sync(CML.at_time(target))

      elapsed = Time.monotonic - start
      elapsed.should be >= 40.milliseconds # Allow some slack
      elapsed.should be < 200.milliseconds
    end

    it "fires immediately if time is in the past" do
      target = Time.utc - 1.second
      start = Time.monotonic

      CML.sync(CML.at_time(target))

      elapsed = Time.monotonic - start
      elapsed.should be < 50.milliseconds # Should be nearly instant
    end
  end

  describe "ThreadId" do
    it "provides current thread ID" do
      tid = CML.get_tid
    tid.should be_a(CML::Thread::Id)
  end

    it "returns same ID for same fiber" do
      tid1 = CML.get_tid
      tid2 = CML.get_tid
      CML.same_tid(tid1, tid2).should be_true
    end

    it "returns different IDs for different fibers" do
      tid1 = CML.get_tid
      tid2 : CML::Thread::Id? = nil

      spawn do
        tid2 = CML.get_tid
      end
      Fiber.yield

      tid2.should_not be_nil
      CML.same_tid(tid1, tid2.not_nil!).should be_false
    end

    it "provides hash and string conversion" do
      tid = CML.get_tid
      CML.hash_tid(tid).should be_a(UInt64)
      CML.tid_to_string(tid).should match(/ThreadId\(\d+\)/)
    end

    it "supports comparison" do
      tid1 = CML.get_tid
      tid2 : CML::Thread::Id? = nil

      spawn do
        tid2 = CML.get_tid
      end
      Fiber.yield

      # IDs should be different and have consistent ordering
      cmp = CML.compare_tid(tid1, tid2.not_nil!)
      cmp.should_not eq(0)
    end
  end

  describe "spawn" do
    it "spawns a new thread and returns ThreadId" do
      executed = false
      tid = CML.spawn do
        executed = true
      end

      tid.should be_a(CML::Thread::Id)
      Fiber.yield
      executed.should be_true
    end

    it "marks thread as exited when done" do
      tid = CML.spawn do
        # Quick task
      end

      tid.exited?.should be_false
      sleep 10.milliseconds
      tid.exited?.should be_true
    end
  end

  describe "spawnc" do
    it "spawns with an argument" do
      result = 0
      tid = CML.spawnc(42) do |x|
        result = x * 2
      end

      Fiber.yield
      result.should eq(84)
    end
  end

  describe "joinEvt" do
    it "fires when thread exits" do
      tid = CML.spawn do
        sleep 10.milliseconds
      end

      # Wait for the thread to exit by syncing on join_evt directly
      CML.sync(CML.join_evt(tid))

      # Thread should now be marked as exited
      tid.exited?.should be_true
    end

    it "blocks until thread exits" do
      start = Time.monotonic
      tid = CML.spawn do
        sleep 30.milliseconds
      end

      CML.sync(CML.join_evt(tid))
      elapsed = Time.monotonic - start

      elapsed.should be >= 25.milliseconds
    end

    it "can be used with choose for timeout" do
      tid = CML.spawn do
        sleep 200.milliseconds # Long-running task
      end

      result = CML.sync(CML.choose(
        CML.wrap(CML.join_evt(tid)) { :joined },
        CML.wrap(CML.timeout(30.milliseconds)) { :timeout }
      ))

      result.should eq(:timeout)
    end
  end

  describe "ThreadProp" do
    it "provides thread-local storage with lazy init" do
      prop = CML.new_thread_prop(Int32) { 42 }

      prop.peek.should be_nil # Not initialized yet
      prop.get.should eq(42)  # Initializes and returns
      prop.peek.should eq(42) # Now has value

      prop.set(100)
      prop.get.should eq(100)

      prop.clear
      prop.peek.should be_nil
      prop.get.should eq(42) # Re-initializes
    end

    it "isolates values between threads" do
      prop = CML.new_thread_prop(Int32) { 0 }
      prop.set(1)

      other_value : Int32? = nil
      spawn do
        other_value = prop.get
        prop.set(2)
      end
      Fiber.yield

      prop.get.should eq(1)    # Main fiber's value unchanged
      other_value.should eq(0) # Other fiber got fresh init
    end
  end

  describe "ThreadFlag" do
    it "provides thread-local boolean" do
      flag = CML.new_thread_flag

      flag.get.should be_false # Defaults to false
      flag.set(true)
      flag.get.should be_true
    end

    it "isolates values between threads" do
      flag = CML.new_thread_flag
      flag.set(true)

      other_value : Bool? = nil
      spawn do
        other_value = flag.get
      end
      Fiber.yield

      flag.get.should be_true
      other_value.should be_false # Other fiber has its own value
    end
  end

  describe "Barrier" do
    it "synchronizes multiple threads" do
      barrier = CML.counting_barrier(0)
      e1 = barrier.enroll
      e2 = barrier.enroll

      results = [] of Int32

      spawn do
        results << 1
        e1.wait
        results << 3
      end

      spawn do
        results << 2
        e2.wait
        results << 4
      end

      Fiber.yield
      sleep 10.milliseconds # Allow both to reach barrier

      # Both should have completed wait
      results.should contain(1)
      results.should contain(2)
      results.should contain(3)
      results.should contain(4)
    end

    it "updates state on synchronization" do
      barrier = CML.counting_barrier(0)
      e1 = barrier.enroll
      e2 = barrier.enroll

      result1 : Int32? = nil
      result2 : Int32? = nil

      spawn do
        result1 = e1.wait
      end

      spawn do
        result2 = e2.wait
      end

      sleep 20.milliseconds

      # Both should get the updated state (incremented by 1)
      result1.should eq(1)
      result2.should eq(1)
    end

    it "allows enrollment queries" do
      barrier = CML.barrier(0) { |x| x + 1 }
      e = barrier.enroll

      e.enrolled?.should be_true
      e.waiting?.should be_false
      e.resigned?.should be_false
    end

    it "allows resignation" do
      barrier = CML.counting_barrier(0)
      e1 = barrier.enroll
      e2 = barrier.enroll

      # One enrollee resigns
      e1.resign

      # Now barrier should trigger when just e2 waits
      result : Int32? = nil
      spawn do
        result = e2.wait
      end

      sleep 20.milliseconds
      result.should eq(1)
    end

    it "provides current value" do
      barrier = CML.barrier(42) { |x| x + 1 }
      e = barrier.enroll

      e.value.should eq(42)
    end

    it "supports wait_evt for use in choose" do
      barrier = CML.counting_barrier(0)
      e1 = barrier.enroll
      e2 = barrier.enroll

      spawn do
        sleep 10.milliseconds
        e2.wait
      end

      # Use wait_evt with timeout
      result = CML.sync(CML.choose(
        CML.wrap(e1.wait_evt) { |n| {:barrier, n} },
        CML.wrap(CML.timeout(50.milliseconds)) { {:timeout, -1} }
      ))

      result[0].should eq(:barrier)
      result[1].should eq(1)
    end
  end
end
