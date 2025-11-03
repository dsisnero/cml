require "./spec_helper"

module CML
  describe "choose with multiple same-T and a timeout" do
    it "chooses among three Int events and a timeout (4-arg varargs)" do
      ch1 = Chan(Int32).new
      ch2 = Chan(Int32).new
      ch3 = Chan(Int32).new

      # Make ch2 fire first
      spawn { CML.sync(ch2.send_evt(42)) }

      result = CML.sync(CML.choose(ch1.recv_evt, ch2.recv_evt, ch3.recv_evt, CML.timeout(5.milliseconds)))

      # Should be the value from ch2; ensure it's an Int32 not :timeout
      result.should be_a(Int32)
      result.should eq 42
    end

    it "returns :timeout when no channels fire" do
      ch1 = Chan(Int32).new
      ch2 = Chan(Int32).new
      ch3 = Chan(Int32).new

      result = CML.sync(CML.choose(ch1.recv_evt, ch2.recv_evt, ch3.recv_evt, CML.timeout(1.millisecond)))
      result.should eq :timeout
    end
  end
end
