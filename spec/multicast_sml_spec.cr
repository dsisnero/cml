require "./spec_helper"
require "../src/cml"
require "../src/cml/multicast_sml"

describe CML::MulticastChan do
  describe "basic creation" do
    it "creates a multicast channel" do
      chan = CML::MulticastChan(Int32).new
      chan.should_not be_nil
    end

    it "creates via convenience function" do
      chan = CML.m_channel_sml(Int32)
      chan.should_not be_nil
    end
  end

  describe "port creation" do
    it "creates a port from a multicast channel" do
      chan = CML::MulticastChan(Int32).new
      port = chan.port
      port.should_not be_nil
    end

    it "creates multiple ports" do
      chan = CML::MulticastChan(Int32).new
      port1 = chan.port
      port2 = chan.port
      port1.should_not be_nil
      port2.should_not be_nil
    end
  end

  # Note: The full multicast semantics require proper IVar blocking.
  # These tests verify the basic API works.
  it "multicast messaging delivers to all ports" do
    mchan = CML::MulticastChan(Int32).new
    port1 = mchan.port
    port2 = mchan.port

    # Multicast a value
    mchan.multicast(42)

    # Both ports should receive
    CML.sync(port1.recv_evt).should eq(42)
    CML.sync(port2.recv_evt).should eq(42)
  end
end