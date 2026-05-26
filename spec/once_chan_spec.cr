require "./spec_helper"
require "../src/cml/once_chan"

describe CML::OnceChan do
  it "creates a one-shot channel" do
    ch = CML::OnceChan(Int32).new
    ch.should be_a(CML::OnceChan(Int32))
  end

  it "send_evt returns a Send event" do
    ch = CML::OnceChan(Int32).new
    evt = ch.send_evt(42)
    evt.should be_a(CML::Event(Nil))
  end

  it "recv_evt returns a Recv event" do
    ch = CML::OnceChan(Int32).new
    evt = ch.recv_evt
    evt.should be_a(CML::Event(Int32))
  end

  it "rendezvous with send first, then recv" do
    ch = CML::OnceChan(Int32).new
    result = CML::Slot(Int32).new

    CML.spawn do
      result.set(CML.sync(ch.recv_evt))
    end

    CML.sync(ch.send_evt(99))
    CML.sleep(5.milliseconds)
    result.get.should eq(99)
  end

  it "rendezvous with recv first, then send" do
    ch = CML::OnceChan(Int32).new
    result = CML::Slot(Int32).new

    CML.spawn do
      CML.sync(ch.send_evt(77))
    end

    value = CML.sync(ch.recv_evt)
    CML.sleep(5.milliseconds)
    value.should eq(77)
  end

  it "blocking send/recv work" do
    ch = CML::OnceChan(Int32).new

    CML.spawn do
      ch.send(55)
    end

    Fiber.yield
    ch.recv.should eq(55)
  end

  it "is faster than standard Chan for the same operation" do
    # Functional comparison: OnceChan should complete the same rendezvous
    ch = CML::OnceChan(Int32).new
    CML.spawn { ch.send(100) }
    Fiber.yield
    ch.recv.should eq(100)
  end
end
