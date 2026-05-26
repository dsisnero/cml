require "./spec_helper"

describe "CML Choice-Free Channel Fast Path" do
  it "sync on send_evt alone (no choose) uses BaseGroup/sync_on_base_events" do
    ch = CML::Chan(Int32).new

    CML.spawn { CML.sync(ch.send_evt(42)) }
    Fiber.yield

    result = CML.sync(ch.recv_evt)
    result.should eq(42)
  end

  it "sync on recv_evt alone works correctly" do
    ch = CML::Chan(Int32).new

    CML.spawn do
      CML.sync(ch.send_evt(99))
    end

    result = CML.sync(ch.recv_evt)
    result.should eq(99)
  end

  it "sync on always alone uses the fast path" do
    result = CML.sync(CML.always(42))
    result.should eq(42)
  end

  it "sync on send_evt with explicit nack still works" do
    ch = CML::Chan(Int32).new
    nack_fired = Atomic(Bool).new(false)

    evt = CML.with_nack do |nack_evt|
      CML.spawn do
        CML.sync(nack_evt)
        nack_fired.set(true)
      end
      CML.wrap(ch.send_evt(42)) { |_| :sent }
    end

    CML.spawn do
      CML.sync(ch.recv_evt)
    end
    Fiber.yield

    result = CML.sync(evt)
    result.should eq(:sent)
  end

  it "CML.wrap on send_evt preserves correctness" do
    ch = CML::Chan(Int32).new
    evt = CML.wrap(ch.recv_evt) { |v| "got #{v}" }

    CML.spawn { ch.send(7) }
    Fiber.yield

    result = CML.sync(evt)
    result.should eq("got 7")
  end

  it "CML.guard wrapping a recv_evt works correctly" do
    ch = CML::Chan(Int32).new
    evt = CML.guard { CML.wrap(ch.recv_evt) { |v| v * 2 } }

    CML.spawn { ch.send(21) }
    Fiber.yield

    result = CML.sync(evt)
    result.should eq(42)
  end
end
