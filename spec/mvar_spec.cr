require "./spec_helper"
require "../src/cml"
require "../src/mvar"

describe CML::MVar do
  describe "initialization" do
    it "creates an empty MVar" do
      mvar = CML::MVar(Int32).new
      mvar.poll.should be_nil
    end

    it "creates an MVar with initial value" do
      mvar = CML::MVar(Int32).new(42)
      mvar.poll.should eq(42)
    end
  end

  describe "put and take" do
    it "puts and takes a value" do
      mvar = CML::MVar(Int32).new
      spawn { mvar.put(42) }
      result = mvar.take
      result.should eq(42)
    end

    it "blocks put when full" do
      mvar = CML::MVar(Int32).new(1)
      done = Channel(Nil).new(1)

      spawn do
        mvar.put(2) # Should block until taken
        done.send(nil)
      end

      sleep 10.milliseconds
      mvar.take.should eq(1)
      done.receive
      mvar.take.should eq(2)
    end

    it "blocks take when empty" do
      mvar = CML::MVar(String).new
      done = Channel(String).new(1)

      spawn do
        result = mvar.take # Should block until put
        done.send(result)
      end

      sleep 10.milliseconds
      mvar.put("hello")
      done.receive.should eq("hello")
    end
  end

  describe "get (read without removing)" do
    it "reads without removing the value" do
      mvar = CML::MVar(Int32).new(42)
      mvar.get.should eq(42)
      mvar.get.should eq(42) # Still there
      mvar.poll.should eq(42)
    end

    it "blocks when empty" do
      mvar = CML::MVar(Int32).new
      done = Channel(Int32).new(1)

      spawn do
        result = mvar.get
        done.send(result)
      end

      sleep 10.milliseconds
      mvar.put(99)
      done.receive.should eq(99)
      mvar.poll.should eq(99) # Still there after get
    end
  end

  describe "swap" do
    it "atomically swaps values" do
      mvar = CML::MVar(Int32).new(10)
      old_value = mvar.swap(20)
      old_value.should eq(10)
      mvar.poll.should eq(20)
    end

    it "blocks when empty" do
      mvar = CML::MVar(String).new
      done = Channel(String).new(1)

      spawn do
        old = mvar.swap("new")
        done.send(old)
      end

      sleep 10.milliseconds
      mvar.put("old")
      done.receive.should eq("old")
      mvar.poll.should eq("new")
    end

    it "handles multiple swaps" do
      mvar = CML::MVar(Int32).new(0)

      results = [] of Int32
      5.times do |i|
        results << mvar.swap(i + 1)
      end

      results.should eq([0, 1, 2, 3, 4])
      mvar.poll.should eq(5)
    end
  end

  describe "swap_evt" do
    it "creates a swap event" do
      mvar = CML::MVar(Int32).new(100)
      evt = mvar.swap_evt(200)
      old_value = CML.sync(evt)
      old_value.should eq(100)
      mvar.poll.should eq(200)
    end
  end

  describe "take_poll (non-blocking)" do
    it "returns value when full" do
      mvar = CML::MVar(Int32).new(42)
      mvar.take_poll.should eq(42)
      mvar.take_poll.should be_nil # Now empty
    end

    it "returns nil when empty" do
      mvar = CML::MVar(Int32).new
      mvar.take_poll.should be_nil
    end
  end

  describe "poll (non-blocking)" do
    it "returns value when full" do
      mvar = CML::MVar(Int32).new(42)
      mvar.poll.should eq(42)
      mvar.poll.should eq(42) # Still there
    end

    it "returns nil when empty" do
      mvar = CML::MVar(Int32).new
      mvar.poll.should be_nil
    end
  end

  describe "put_evt" do
    it "creates a put event" do
      mvar = CML::MVar(Int32).new
      spawn { mvar.take }
      evt = mvar.put_evt(42)
      CML.sync(evt)
      # Should complete
    end
  end

  describe "take_evt" do
    it "creates a take event" do
      mvar = CML::MVar(Int32).new
      spawn { mvar.put(42) }
      evt = mvar.take_evt
      result = CML.sync(evt)
      result.should eq(42)
    end
  end

  describe "read_evt" do
    it "creates a read event" do
      mvar = CML::MVar(Int32).new(42)
      evt = mvar.read_evt
      result = CML.sync(evt)
      result.should eq(42)
      mvar.poll.should eq(42) # Still there
    end
  end

  describe "concurrent access" do
    it "handles multiple producers and consumers" do
      mvar = CML::MVar(Int32).new
      results = Channel(Int32).new(10)

      # Producers
      5.times do |i|
        spawn { mvar.put(i) }
      end

      # Consumers
      5.times do
        spawn { results.send(mvar.take) }
      end

      collected = [] of Int32
      5.times { collected << results.receive }
      collected.sort.should eq([0, 1, 2, 3, 4])
    end

    it "handles readers not consuming the value" do
      mvar = CML::MVar(Int32).new(42)
      results = Channel(Int32).new(3)

      3.times do
        spawn { results.send(mvar.get) }
      end

      3.times { results.receive.should eq(42) }
      mvar.poll.should eq(42) # Still there
    end
  end
end
