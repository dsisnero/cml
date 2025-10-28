require "./spec_helper"

module CML
  describe "select macro" do
    it "selects the first ready event and runs the correct handler" do
      ch1 = Chan(Int32).new
      ch2 = Chan(Int32).new
      spawn { CML.sync(ch2.send_evt(42)) }
      result = CML.select([
        {ch1.recv_evt, ->(x : Int32?) : Int32 { (x || 0) + 1 }},
        {ch2.recv_evt, ->(y : Int32?) : Int32 { (y || 0) * 2 }},
      ])
      result.should eq(84)
    end

    it "selects the first to complete if none are ready" do
      ch = Chan(Int32).new
      spawn { CML.sync(ch.send_evt(7)) }
      result = CML.select([
        {ch.recv_evt, ->(x : Int32?) : Int32 { (x || 0) * 3 }},
        {CML.never(Int32), ->(y : Int32?) : Int32 { y || 0 }},
      ])
      result.should eq(21)
    end

    it "works with immediate events" do
      result = CML.select([
        {CML.always(5), ->(x : Int32?) : Int32 { (x || 0) * 2 }},
        {CML.always(10), ->(y : Int32?) : Int32 { (y || 0) + 1 }},
      ])
      # The first branch should win
      result.should eq(10)
    end
  end
end
