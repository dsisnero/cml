require "./spec_helper"

module CML
  describe "with_timeout" do
    it "returns result and :ok if event completes before timeout" do
      ch = Chan(Int32).new
      spawn { CML.sync(ch.send_evt(7)) }
      result = CML.sync(CML.with_timeout(ch.recv_evt, 0.5.seconds))
      result.should eq({7, :ok})
    end

    it "returns nil and :timeout if timeout fires first" do
      ch = Chan(Int32).new
      result = CML.sync(CML.with_timeout(ch.recv_evt, 0.01.seconds))
      result.should eq({nil, :timeout})
    end
  end
end
