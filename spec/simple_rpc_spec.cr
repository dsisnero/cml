require "./spec_helper"
require "../src/cml"
require "../src/cml/simple_rpc"

describe "CML SimpleRPC" do
  describe "mk_rpc (stateless)" do
    it "creates a simple RPC" do
      double_fn = ->(x : Int32) { x * 2 }
      rpc = CML.mk_rpc(double_fn)
      rpc.should_not be_nil
    end

    it "makes RPC calls" do
      double_fn = ->(x : Int32) { x * 2 }
      rpc = CML.mk_rpc(double_fn)

      # Start server fiber
      spawn do
        loop do
          CML.sync(rpc.entry_evt)
        end
      end

      sleep 10.milliseconds
      result = rpc.call.call(21)
      result.should eq(42)
    end

    it "handles multiple calls" do
      upcase_fn = ->(s : String) { s.upcase }
      rpc = CML.mk_rpc(upcase_fn)

      spawn do
        3.times { CML.sync(rpc.entry_evt) }
      end

      sleep 10.milliseconds
      rpc.call.call("hello").should eq("HELLO")
      rpc.call.call("world").should eq("WORLD")
      rpc.call.call("test").should eq("TEST")
    end

    it "handles different types" do
      to_string_fn = ->(x : Float64) { x.to_s }
      rpc = CML.mk_rpc(to_string_fn)

      spawn do
        CML.sync(rpc.entry_evt)
      end

      sleep 10.milliseconds
      result = rpc.call.call(3.14)
      result.should eq("3.14")
    end
  end

  describe "concurrent calls" do
    it "handles multiple concurrent callers" do
      slow_double = ->(x : Int32) { sleep 5.milliseconds; x * 2 }
      rpc = CML.mk_rpc(slow_double)

      # Server handles all requests
      spawn do
        10.times { CML.sync(rpc.entry_evt) }
      end

      results = Channel(Int32).new(10)

      10.times do |i|
        spawn do
          result = rpc.call.call(i)
          results.send(result)
        end
      end

      sleep 200.milliseconds

      collected = [] of Int32
      10.times { collected << results.receive }
      collected.sort.should eq([0, 2, 4, 6, 8, 10, 12, 14, 16, 18])
    end
  end
end