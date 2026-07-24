require "./spec_helper"

describe "CML::ExecutionContext" do
  {% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 || (flag?(:preview_mt) && flag?(:execution_context)) %}
    it "runs fibers in the custom parallel execution context" do
      ctx = CML::ExecutionContext.new("cml-test", capacity: 2)
      done = Channel(Fiber::ExecutionContext).new

      ctx.spawn do
        done.send(Fiber::ExecutionContext.current)
      end

      done.receive.should eq(ctx)
      ctx.capacity.should eq(2)
    end

    it "does not lose rendezvous registrations under parallel contention" do
      ctx = CML::ExecutionContext.new("cml-rendezvous", capacity: 4)
      ch = CML::Chan(Int32).new
      completed = Channel(Bool).new(64)
      received = Channel(Int32).new(32)

      32.times do |value|
        ctx.spawn do
          CML.sync(ch.send_evt(value))
          completed.send(true)
        end
        ctx.spawn do
          received.send(CML.sync(ch.recv_evt))
          completed.send(true)
        end
      end

      values = Array(Int32).new(32) { received.receive }
      64.times { completed.receive.should be_true }
      values.sort.should eq((0...32).to_a)
    end
  {% else %}
    it "spawns work with fallback context when execution contexts are disabled" do
      ctx = CML::ExecutionContext.new("cml-test")
      done = Channel(Bool).new

      ctx.spawn do
        done.send(true)
      end

      done.receive.should be_true
      ctx.wait
    end
  {% end %}
end
