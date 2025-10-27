require "./spec_helper"

module CML
  describe "wrap_abort" do
    it "runs the block and does not abort if event wins" do
      ch = Chan(Int32).new
      aborted = false
      spawn { CML.sync(ch.send_evt(99)) }
      result = CML.sync(CML.wrap_abort(ch.recv_evt, -> { aborted = true; nil }) { |v| v + 1 })
      result.should eq(100)
      aborted.should be_false
    end

    it "runs abort callback if event loses a choose" do
      ch1 = Chan(Int32).new
      ch2 = Chan(Int32).new
      aborted = false
      ev1 = CML.wrap_abort(ch1.recv_evt, -> { aborted = true; nil }) { |v| v + 1 }
      ev2 = ch2.recv_evt
      spawn { CML.sync(ch2.send_evt(42)) }
      result = CML.sync(CML.choose([ev1, ev2]))
      result.should eq(42)
      aborted.should be_true
    end

    it "does not run abort callback if wrap_abort wins in choose" do
      ch1 = Chan(Int32).new
      ch2 = Chan(Int32).new
      aborted = false
      ev1 = CML.wrap_abort(ch1.recv_evt, -> { aborted = true; nil }) { |v| v + 1 }
      ev2 = ch2.recv_evt
      spawn { CML.sync(ch1.send_evt(10)) }
      result = CML.sync(CML.choose([ev1, ev2]))
      result.should eq(11)
      aborted.should be_false
    end
  end
end
