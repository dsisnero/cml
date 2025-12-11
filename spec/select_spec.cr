require "./spec_helper"

module CML
  describe "select (SML/NJ compatible)" do
    # SML's select is simply: sync(choose(events))
    # It synchronizes on a list of events and returns the result of the winner

    it "selects among multiple channel events" do
      ch1 = Chan(Int32).new
      ch2 = Chan(Int32).new
      spawn { CML.sync(ch2.send_evt(42)) }

      result = CML.select(ch1.recv_evt, ch2.recv_evt)
      result.should eq(42)
    end

    it "selects with array form" do
      ch = Chan(Int32).new
      spawn { CML.sync(ch.send_evt(7)) }

      result = CML.select([ch.recv_evt, CML.always(100)])
      # always(100) wins immediately via poll
      result.should eq(100)
    end

    it "selects the first immediate event via polling" do
      result = CML.select(CML.always(5), CML.always(10))
      # First always wins
      result.should eq(5)
    end

    it "works with timeout events" do
      ch = Chan(Int32).new
      # No sender, so timeout should win
      result = CML.select(
        CML.wrap(ch.recv_evt) { |x| "got: #{x}" },
        CML.wrap(CML.timeout(10.milliseconds)) { |_| "timeout" }
      )
      result.should eq("timeout")
    end

    it "is equivalent to sync(choose(events))" do
      ch = Chan(Int32).new
      spawn { CML.sync(ch.send_evt(99)) }

      # These should be equivalent
      result1 = CML.select(ch.recv_evt, CML.always(1))

      ch2 = Chan(Int32).new
      spawn { CML.sync(ch2.send_evt(99)) }
      result2 = CML.sync(CML.choose(ch2.recv_evt, CML.always(1)))

      # Both should get 1 (always wins via poll)
      result1.should eq(1)
      result2.should eq(1)
    end
  end
end
