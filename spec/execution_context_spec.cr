require "./spec_helper"

describe "CML::ExecutionContext" do
  {% if flag?(:preview_mt) && flag?(:execution_context) %}
    it "runs fibers in the custom execution context" do
      ctx = CML::ExecutionContext.new("cml-test")
      done = Channel(Fiber::ExecutionContext).new

      ctx.spawn do
        done.send(Fiber::ExecutionContext.current)
      end

      done.receive.should eq(ctx)
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
