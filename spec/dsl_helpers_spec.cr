require "spec"
require "../src/cml"

describe CML do
  describe ".after" do
    it "runs a block after the given span" do
      flag = false
      ch = CML.after(0.01.seconds) { flag = true }
      ch.receive
      flag.should be_true
    end
  end

  describe ".spawn_evt" do
    it "returns an event that completes with the block's result" do
      evt = CML.spawn_evt { 42 }
      CML.sync(evt).should eq(42)
    end

    it "works with side effects" do
      arr = [] of Int32
      evt = CML.spawn_evt { arr << 1; 99 }
      CML.sync(evt).should eq(99)
      arr.should eq([1])
    end
  end
end
