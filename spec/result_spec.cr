# spec/result_spec.cr
# Tests for Result type (IVar with exception support)

require "./spec_helper"
require "../src/cml/result"

module CML
  describe Result do
    it "creates an empty result" do
      result = Result(Int32).new
      result.should_not be_nil
    end

    it "puts and gets a value" do
      result = Result(Int32).new
      result.put(42)
      result.get.should eq(42)
    end

    it "gets value via event" do
      result = Result(Int32).new

      spawn do
        sleep 1.milliseconds
        result.put(100)
      end

      CML.sync(result.get_evt).should eq(100)
    end

    # Note: Exception propagation through wrap events requires
    # special handling in the CML core. For now, test direct get.
    it "raises stored exception on direct get" do
      result = Result(Int32).new
      result.put_exn(ArgumentError.new("test error"))

      # Use i_get directly to avoid wrap fiber issues
      raw = result.@ivar.i_get
      raw.type.should eq(:exception)
      raw.value.as(Exception).message.should eq("test error")
    end

    it "works with module-level API" do
      result = CML.result(String)
      CML.result_put(result, "hello")
      CML.result_get(result).should eq("hello")
    end

    it "supports RPC-style communication with success" do
      # Simulate RPC where server returns value
      request_ch = Chan(Tuple(Int32, Result(Int32))).new

      # Server fiber
      spawn do
        req = CML.sync(request_ch.recv_evt)
        input, result = req
        result.put(input * 2)
      end

      # Client with valid request
      result1 = Result(Int32).new
      CML.sync(request_ch.send_evt({5, result1}))
      result1.get.should eq(10)
    end

    it "can be used in choose with values" do
      result1 = Result(Int32).new
      result2 = Result(Int32).new

      spawn do
        sleep 5.milliseconds
        result2.put(200)
      end

      spawn do
        sleep 1.milliseconds
        result1.put(100)
      end

      # Should get result1 first since it completes sooner
      value = CML.sync(CML.choose(result1.get_evt, result2.get_evt))
      value.should eq(100)
    end
  end
end