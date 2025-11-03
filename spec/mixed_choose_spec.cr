require "./spec_helper"

describe CML do
  describe "choose with heterogeneous events" do
    it "supports varargs choose across mixed result types" do
      e1 = CML.always(42)
      e2 = CML.timeout(1.millisecond)
      result = CML.sync(CML.choose(e1, e2))
      # always should win immediately
      result.should eq 42
    end

    it "supports three heterogeneous events" do
      e1 = CML.always(1)
      e2 = CML.always("ok")
      e3 = CML.timeout(1.millisecond)
      result = CML.sync(CML.choose(e1, e2, e3))
      # first always wins deterministically in our implementation
      result.should eq 1
    end
  end
end
