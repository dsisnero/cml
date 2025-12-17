require "spec"
require "../src/cml/simple_rpc"

describe RPC do
  describe "mk_rpc (stateless)" do
    it "creates a working RPC endpoint and handles single call" do
      rpc = RPC.mk_rpc(Int32, Int32) { |n| n * 2 }

      # Start server
      spawn { CML.sync(rpc.entry_evt) }
      Fiber.yield

      result = rpc.call.call(21)
      result.should eq(42)
    end

    it "handles multiple sequential calls" do
      rpc = RPC.mk_rpc(Int32, String) { |n| "Value: #{n}" }

      # Server handles 3 requests
      spawn { CML.sync(rpc.entry_evt) }
      spawn { CML.sync(rpc.entry_evt) }
      spawn { CML.sync(rpc.entry_evt) }
      Fiber.yield

      rpc.call.call(1).should eq("Value: 1")
      rpc.call.call(2).should eq("Value: 2")
      rpc.call.call(3).should eq("Value: 3")
    end

    it "works with complex types" do
      rpc = RPC.mk_rpc(Array(Int32), Int32) { |arr| arr.sum }

      spawn { CML.sync(rpc.entry_evt) }
      spawn { CML.sync(rpc.entry_evt) }
      Fiber.yield

      rpc.call.call([1, 2, 3]).should eq(6)
      rpc.call.call([10, 20]).should eq(30)
    end
  end

  describe "mk_rpc_in (input state)" do
    it "passes state to the handler" do
      multiplier = 2
      rpc = RPC.mk_rpc_in(Int32, Int32, Int32) { |n, mult| n * mult }

      # Server uses the same state for both calls
      spawn { CML.sync(rpc.entry_evt.call(multiplier)) }
      spawn { CML.sync(rpc.entry_evt.call(multiplier)) }
      Fiber.yield

      rpc.call.call(5).should eq(10) # 5 * 2
      rpc.call.call(3).should eq(6)  # 3 * 2
    end
  end

  describe "mk_rpc_out (output state)" do
    it "returns new state from handler" do
      rpc = RPC.mk_rpc_out(Int32, Int32, Int32) { |n| {n * 2, n} }

      last_state = 0
      spawn { last_state = CML.sync(rpc.entry_evt) }
      Fiber.yield

      rpc.call.call(5).should eq(10)
      sleep 5.milliseconds
      last_state.should eq(5)
    end
  end

  describe "mk_rpc_in_out (input/output state)" do
    it "maintains state across calls with proper server loop" do
      rpc = RPC.mk_rpc_in_out(String, Int32, Int32) do |cmd, count|
        case cmd
        when "inc"   then {count + 1, count + 1}
        when "get"   then {count, count}
        when "reset" then {0, 0}
        else              {-1, count}
        end
      end

      # Server with proper state chaining
      done = Channel(Nil).new
      spawn do
        state = 0
        7.times do
          state = CML.sync(rpc.entry_evt.call(state))
        end
        done.send(nil)
      end
      Fiber.yield

      rpc.call.call("get").should eq(0)
      rpc.call.call("inc").should eq(1)
      rpc.call.call("inc").should eq(2)
      rpc.call.call("inc").should eq(3)
      rpc.call.call("get").should eq(3)
      rpc.call.call("reset").should eq(0)
      rpc.call.call("get").should eq(0)

      done.receive # Wait for server to finish
    end
  end
end
