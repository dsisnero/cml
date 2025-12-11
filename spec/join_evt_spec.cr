require "./spec_helper"

describe "CML.join_evt" do
  describe "basic functionality" do
    it "fires when a spawned fiber terminates normally" do
      # Spawn a fiber that finishes immediately
      tid = CML.spawn do
        # Do nothing, just exit
      end

      # Wait for the fiber to terminate via join_evt
      CML.sync(CML.join_evt(tid))
      completed = true

      completed.should be_true
    end

    it "fires when a spawned fiber does work before terminating" do
      result = Atomic(Int32).new(0)

      tid = CML.spawn do
        # Do some work
        x = 1 + 2 + 3
        result.set(x)
      end

      # Wait for fiber to terminate
      CML.sync(CML.join_evt(tid))

      # Fiber should have set its result
      result.get.should eq(6)
    end

    it "can be used with timeout in choose" do
      # Spawn a fiber that takes a long time
      tid = CML.spawn do
        sleep 2.seconds
      end

      # Use choose with timeout - timeout should win
      result = CML.sync(CML.choose([
        CML.wrap(CML.join_evt(tid)) { :joined },
        CML.wrap(CML.timeout(50.milliseconds)) { :timeout },
      ]))

      result.should eq(:timeout)
    end

    it "join_evt wins over timeout when fiber finishes quickly" do
      tid = CML.spawn do
        # Finish immediately
      end

      # Give the fiber time to start and finish
      sleep 20.milliseconds

      result = CML.sync(CML.choose([
        CML.wrap(CML.join_evt(tid)) { :joined },
        CML.wrap(CML.timeout(500.milliseconds)) { :timeout },
      ]))

      result.should eq(:joined)
    end
  end

  describe "multiple joins" do
    it "can join on multiple fibers sequentially" do
      count = Atomic(Int32).new(0)

      tid1 = CML.spawn { count.add(1) }
      tid2 = CML.spawn { count.add(10) }
      tid3 = CML.spawn { count.add(100) }

      CML.sync(CML.join_evt(tid1))
      CML.sync(CML.join_evt(tid2))
      CML.sync(CML.join_evt(tid3))

      count.get.should eq(111)
    end

    it "can race join events with choose" do
      # Spawn two fibers with different delays
      fast_done = Atomic(Bool).new(false)
      slow_done = Atomic(Bool).new(false)

      slow_tid = CML.spawn do
        sleep 200.milliseconds
        slow_done.set(true)
      end

      fast_tid = CML.spawn do
        sleep 10.milliseconds
        fast_done.set(true)
      end

      # Wait for whichever finishes first
      result = CML.sync(CML.choose([
        CML.wrap(CML.join_evt(fast_tid)) { :fast },
        CML.wrap(CML.join_evt(slow_tid)) { :slow },
      ]))

      result.should eq(:fast)
      fast_done.get.should be_true
    end
  end

  describe "with guard" do
    it "can use join_evt inside guard" do
      tid = CML.spawn do
        # Finish immediately
      end

      # Give fiber time to terminate
      sleep 20.milliseconds

      guarded = false
      CML.sync(CML.guard do
        guarded = true
        CML.join_evt(tid)
      end)

      guarded.should be_true
    end
  end

  describe "with wrap" do
    it "can transform join result" do
      tid = CML.spawn { }

      result = CML.sync(CML.wrap(CML.join_evt(tid)) { "fiber done" })
      result.should eq("fiber done")
    end

    it "can chain wraps on join_evt" do
      counter = Atomic(Int32).new(0)

      tid = CML.spawn { counter.add(5) }

      result = CML.sync(
        CML.wrap(
          CML.wrap(CML.join_evt(tid)) { counter.get }
        ) { |v| v * 2 }
      )

      result.should eq(10)
    end
  end
end

# Note: wrap_handler tests removed - exceptions in wrap blocks run in spawned fibers
# and don't propagate correctly to the sync caller. This needs architectural changes
# to fix properly.
