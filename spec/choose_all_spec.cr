require "./spec_helper"

module CML
  describe "choose_all" do
    it "returns all immediately ready results" do
      ev1 = CML.always(1)
      ev2 = CML.always(2)
      ev3 = CML.never(Int32)
      result = CML.sync(CML.choose_all(ev1, ev2, ev3))
      result.sort.should eq([1, 2])
    end

    it "returns singleton array for first to complete if none ready" do
      ch = Chan(Int32).new
      ev1 = ch.recv_evt
      ev2 = CML.never(Int32)
      spawn { CML.sync(ch.send_evt(42)) }
      result = CML.sync(CML.choose_all(ev1, ev2))
      result.should eq([42])
    end

    it "works with empty input (returns empty array)" do
      result = CML.sync(CML.choose_all(Array(Event(Int32)).new))
      result.should eq(Array(Int32).new)
    end
  end
end
