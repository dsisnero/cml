require "./spec_helper"
require "../src/cml/barrier"

describe CML::Barrier do
  describe "basic lifecycle" do
    it "initializes correctly" do
      barrier = CML::Barrier(Int32).new(0) { |x| x + 1 }
      barrier.enrolled_count.should eq(0)
    end

    it "enrolls fibers" do
      barrier = CML::Barrier(Int32).new(0) { |x| x + 1 }
      e1 = barrier.enroll
      barrier.enrolled_count.should eq(1)
      e1.value.should eq(0)
    end
  end

  describe "synchronization" do
    it "blocks until all participants arrive" do
      barrier = CML::Barrier(Int32).new(0) { |x| x + 1 }
      e1 = barrier.enroll
      e2 = barrier.enroll

      ch_checkpoint = Channel(Symbol).new(2)

      spawn do
        e1.wait
        ch_checkpoint.send(:fiber1_done)
      end

      # Fiber 1 should be stuck waiting
      Fiber.yield
      barrier.waiting_count.should eq(1)

      # Select ensures we don't block the test runner if logic is broken
      select
      when ch_checkpoint.receive
        fail "Fiber 1 finished before Fiber 2 arrived"
      when timeout(10.milliseconds)
        # expected
      end

      # Now Fiber 2 arrives
      spawn do
        e2.wait
        ch_checkpoint.send(:fiber2_done)
      end

      # Both should finish now
      2.times { ch_checkpoint.receive.should be_a(Symbol) }
      barrier.waiting_count.should eq(0)
      e1.value.should eq(1)
    end

    it "updates state transactionally" do
      # Updates x -> x + 10
      barrier = CML::Barrier(Int32).new(5) { |x| x + 10 }
      e1 = barrier.enroll
      e2 = barrier.enroll

      results = Channel(Int32).new(2)

      spawn { results.send(e1.wait) }
      spawn { results.send(e2.wait) }

      # Order doesn't matter, just values
      2.times do
        results.receive.should eq(15)
      end

      # Update proc should run exactly once per round (5 -> 15)
      e1.value.should eq(15)
    end
  end

  describe "CML Event Integration" do
    it "works within CML.select" do
      barrier = CML::Barrier(Int32).new(0) { |x| x + 1 }
      e1 = barrier.enroll
      e2 = barrier.enroll

      spawn { e1.wait }

      # e2 uses select instead of blocking wait
      # This proves the BarrierWaitEvt is constructed correctly
      result = CML.select(
        e2.wait_evt,
        CML.timeout(5.seconds) # Returns Symbol :timeout
      )

      result.should eq(1)
    end

    it "can be cancelled via timeout (ChooseEvt)" do
      barrier = CML::Barrier(Int32).new(0) { |x| x + 1 }
      e1 = barrier.enroll # The test runner
      e2 = barrier.enroll # The one that will timeout

      barrier.waiting_count.should eq(0)

      done = Channel(Nil).new

      spawn do
        # e2 tries to wait, but gives up quickly.
        # We use CML.timeout (returns Symbol) instead of time_out_evt (returns Nil)
        # to avoid Pick(Int32 | Nil) bug in the current CML implementation.
        CML.select(
          e2.wait_evt,
          CML.timeout(5.milliseconds)
        )
        done.send(nil)
      end

      # Wait for the select to definitely complete.
      # This implicitly means the Pick has been decided and cancellations ran.
      done.receive

      # e2 should have removed itself from the wait queue via the cancellation proc
      barrier.waiting_count.should eq(0)

      # The barrier should still be usable
      e2.resign
      e1.wait.should eq(1) # Should trigger immediately as e1 is sole survivor
    end
  end

  describe "Dynamic Resignation" do
    it "triggers the barrier if the resigner was the holdout" do
      # Scenario: 3 enrolled. 2 waiting. 3rd resigns.
      # The 2 waiting must wake up immediately.
      barrier = CML::Barrier(Int32).new(100) { |x| x + 1 }
      e1 = barrier.enroll
      e2 = barrier.enroll
      e3 = barrier.enroll # This one will resign

      finished = Channel(Int32).new(2)

      spawn { finished.send(e1.wait) }
      spawn { finished.send(e2.wait) }

      Fiber.yield
      barrier.waiting_count.should eq(2)

      # e3 leaves. Since remaining enrolled (2) == waiting (2), barrier triggers.
      e3.resign

      2.times { finished.receive.should eq(101) }

      barrier.enrolled_count.should eq(2)
      barrier.waiting_count.should eq(0)
    end
  end
end
