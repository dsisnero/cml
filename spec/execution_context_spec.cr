require "./spec_helper"

describe "CML::ExecutionContext" do
  it "runs fibers in the custom execution context" do
    ctx = CML::ExecutionContext.new("cml-test")
    done = Channel(Fiber::ExecutionContext).new

    ctx.spawn do
      done.send(Fiber::ExecutionContext.current)
    end

    done.receive.should eq(ctx)
  end
end
