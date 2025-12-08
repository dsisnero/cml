require "./spec_helper"
require "../src/cml"
require "../src/cml/barrier"

describe CML::Barrier do
  describe "basic functionality" do
    it "creates a barrier with initial state" do
      barrier = CML::Barrier(Int32).new(->(x : Int32) { x + 1 }, 0)
      barrier.enrolled_count.should eq(0)
      barrier.waiting_count.should eq(0)
    end

    it "enrolls fibers in a barrier" do
      barrier = CML::Barrier(Int32).new(->(x : Int32) { x + 1 }, 0)
      enrollment = barrier.enroll
      barrier.enrolled_count.should eq(1)
      enrollment.value.should eq(0)
    end

    it "allows multiple enrollments" do
      barrier = CML::Barrier(Int32).new(->(x : Int32) { x + 1 }, 0)
      e1 = barrier.enroll
      e2 = barrier.enroll
      e3 = barrier.enroll
      barrier.enrolled_count.should eq(3)
    end
  end

  describe "synchronization" do
    it "releases all fibers when all arrive at barrier" do
      barrier = CML::Barrier(Int32).new(->(x : Int32) { x + 1 }, 0)
      results = Channel(Int32).new(3)

      3.times do |_|
        enrollment = barrier.enroll
        spawn do
          result = enrollment.wait
          results.send(result)
        end
      end

      # Give fibers time to reach barrier
      sleep 50.milliseconds

      # All should have completed with updated state
      3.times do
        result = results.receive
        result.should eq(1) # 0 + 1 from update function
      end
    end

    it "applies update function when all fibers arrive" do
      counter = 0
      barrier = CML::Barrier(Int32).new(->(x : Int32) { counter += 1; x + 10 }, 5)

      e1 = barrier.enroll
      e2 = barrier.enroll

      done = Channel(Nil).new(2)

      spawn do
        result = e1.wait
        result.should eq(15) # 5 + 10
        done.send(nil)
      end

      spawn do
        result = e2.wait
        result.should eq(15)
        done.send(nil)
      end

      sleep 50.milliseconds
      2.times { done.receive }
      counter.should eq(1) # Update function called exactly once
    end

    it "updates state after each barrier round" do
      barrier = CML::Barrier(Int32).new(->(x : Int32) { x + 1 }, 0)
      e1 = barrier.enroll
      e2 = barrier.enroll

      # Round 1
      done = Channel(Int32).new(2)
      spawn { done.send(e1.wait) }
      spawn { done.send(e2.wait) }
      sleep 50.milliseconds
      2.times { done.receive.should eq(1) }

      # Round 2
      spawn { done.send(e1.wait) }
      spawn { done.send(e2.wait) }
      sleep 50.milliseconds
      2.times { done.receive.should eq(2) }
    end
  end

  describe "resignation" do
    it "allows resigning from a barrier" do
      barrier = CML::Barrier(Int32).new(->(x : Int32) { x + 1 }, 0)
      e1 = barrier.enroll
      e2 = barrier.enroll
      barrier.enrolled_count.should eq(2)

      e1.resign
      barrier.enrolled_count.should eq(1)
    end

    it "raises when waiting after resignation" do
      barrier = CML::Barrier(Int32).new(->(x : Int32) { x + 1 }, 0)
      enrollment = barrier.enroll
      enrollment.resign

      expect_raises(Exception, /after resignation/) do
        enrollment.wait
      end
    end

    it "ignores multiple resignations" do
      barrier = CML::Barrier(Int32).new(->(x : Int32) { x + 1 }, 0)
      enrollment = barrier.enroll
      enrollment.resign
      enrollment.resign # Should not raise
      barrier.enrolled_count.should eq(0)
    end
  end

  describe "value" do
    it "returns current barrier state" do
      barrier = CML::Barrier(String).new(->(x : String) { x + "!" }, "hello")
      enrollment = barrier.enroll
      enrollment.value.should eq("hello")
    end
  end

  describe "counting_barrier convenience" do
    it "creates a counting barrier" do
      barrier = CML.counting_barrier(0)
      e1 = barrier.enroll
      e2 = barrier.enroll

      done = Channel(Int32).new(2)
      spawn { done.send(e1.wait) }
      spawn { done.send(e2.wait) }

      sleep 50.milliseconds
      2.times { done.receive.should eq(1) }
    end
  end
end