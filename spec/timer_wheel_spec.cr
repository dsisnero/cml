require "./spec_helper"

module CML
  describe TimerWheel do
    it "schedules and fires a one-time timer" do
      wheel = TimerWheel.new(tick_duration: 10.milliseconds)
      fired = false

      wheel.schedule(50.milliseconds) { fired = true }

      wheel.advance(40.milliseconds)
      fired.should be_false

      wheel.advance(10.milliseconds)
      fired.should be_true
    end

    it "cancels a timer before it fires" do
      wheel = TimerWheel.new(tick_duration: 10.milliseconds)
      fired = false

      timer_id = wheel.schedule(50.milliseconds) { fired = true }

      wheel.advance(30.milliseconds)
      wheel.cancel(timer_id).should be_true

      wheel.advance(30.milliseconds)
      fired.should be_false
    end

    it "schedules and fires a recurring interval timer" do
      wheel = TimerWheel.new(tick_duration: 10.milliseconds)
      fire_count = 0

      wheel.schedule_interval(50.milliseconds) { fire_count += 1 }

      wheel.advance(50.milliseconds)
      fire_count.should eq(1)

      wheel.advance(50.milliseconds)
      fire_count.should eq(2)

      wheel.advance(100.milliseconds)
      fire_count.should eq(4)
    end

    it "cancels an interval timer" do
      wheel = TimerWheel.new(tick_duration: 10.milliseconds)
      fire_count = 0

      timer_id = wheel.schedule_interval(50.milliseconds) { fire_count += 1 }

      wheel.advance(50.milliseconds)
      fire_count.should eq(1)

      wheel.cancel(timer_id)

      wheel.advance(100.milliseconds)
      fire_count.should eq(1)
    end

    it "handles cascading timers correctly" do
      # This test relies on the default wheel configuration
      # Level 0: 256 slots, 1ms ticks -> ~256ms
      # Level 1: 64 slots -> up to ~16s
      wheel = TimerWheel.new(tick_duration: 1.millisecond)
      fired = false

      # Schedule a timer that will land on a higher-level wheel
      wheel.schedule(300.milliseconds) { fired = true }

      # Advance time enough to cause a cascade
      wheel.advance(299.milliseconds)
      fired.should be_false

      wheel.advance(1.millisecond)
      fired.should be_true
    end

    it "handles a large number of timers" do
      wheel = TimerWheel.new(tick_duration: 1.millisecond)
      fire_count = 0

      100.times do
        wheel.schedule(10.milliseconds) { fire_count += 1 }
      end

      wheel.advance(10.milliseconds)
      fire_count.should eq(100)
    end

    it "advances time correctly in large jumps" do
      wheel = TimerWheel.new(tick_duration: 1.millisecond)
      fired = false

      wheel.schedule(1.second) { fired = true }

      wheel.advance(1.second)
      fired.should be_true
    end
  end
end
