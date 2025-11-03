require "./spec_helper"

require "../src/cml"
require "../src/cml/multicast.cr"
require "../src/cml/mailbox.cr"

# Specs for Multicast (SML-style)
# - Every broadcast reaches all subscriber ports
# - Ports receive messages FIFO per-port
# - Ports created later only receive subsequent messages
# - recv_evt works in choose/select

describe CML do
  it "delivers every message to all subscriber ports" do
    ch = CML.m_channel(Int32)
    p1 = CML.port(ch)
    p2 = CML.port(ch)

    spawn do
      1.upto(3) { |i| CML.multicast(ch, i) }
    end

    r1 = [CML.sync(CML.recv_evt(p1)), CML.sync(CML.recv_evt(p1)), CML.sync(CML.recv_evt(p1))]
    r2 = [CML.sync(CML.recv_evt(p2)), CML.sync(CML.recv_evt(p2)), CML.sync(CML.recv_evt(p2))]

    r1.should eq([1, 2, 3])
    r2.should eq([1, 2, 3])
  end

  it "new ports only receive future messages" do
    ch = CML.m_channel(Int32)
    p1 = CML.port(ch)

    CML.multicast(ch, 1)
    CML.multicast(ch, 2)

    p2 = CML.port(ch)

    CML.multicast(ch, 3)

    # p1 has all three
    [CML.sync(CML.recv_evt(p1)), CML.sync(CML.recv_evt(p1)), CML.sync(CML.recv_evt(p1))].should eq([1, 2, 3])
    # p2 only gets from when it joined
    [CML.sync(CML.recv_evt(p2))].should eq([3])
  end

  it "supports selective receive across ports" do
    ch = CML.m_channel(String)
    p1 = CML.port(ch)
    p2 = CML.port(ch)

    spawn do
      sleep 10.milliseconds
      CML.multicast(ch, "hi")
    end

    # Use choose + wrap to avoid compiler issues with procs in arrays
    result = CML.sync(CML.choose(
      CML.wrap(CML.recv_evt(p2)) { |str| "p2: #{str}" },
      CML.wrap(CML.recv_evt(p1)) { |str| str },
    ))

    ["p2: hi", "hi"].includes?(result).should be_true
  end
end
