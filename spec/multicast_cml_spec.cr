require "spec"
require "../src/cml/multicast"

describe CML::Multicast::Chan do
  describe "basic multicast" do
    it "allows creating a multicast channel" do
      ch = CML.mchannel(Int32)
      ch.should be_a(CML::Multicast::Chan(Int32))
    end

    it "allows creating ports" do
      ch = CML.mchannel(Int32)
      port = ch.port
      port.should be_a(CML::Multicast::Port(Int32))
    end

    it "delivers messages to a single port" do
      ch = CML.mchannel(Int32)
      port = ch.port
      Fiber.yield # Let tee fiber start

      ch.multicast(42)
      result = port.recv
      result.should eq(42)
    end

    it "delivers messages to multiple ports" do
      ch = CML.mchannel(Int32)
      port1 = ch.port
      port2 = ch.port
      Fiber.yield # Let tee fibers start

      ch.multicast(42)

      # Both ports should receive the same message
      result1 = port1.recv
      result2 = port2.recv

      result1.should eq(42)
      result2.should eq(42)
    end

    it "delivers multiple messages in order" do
      ch = CML.mchannel(Int32)
      port = ch.port
      Fiber.yield

      ch.multicast(1)
      ch.multicast(2)
      ch.multicast(3)

      port.recv.should eq(1)
      port.recv.should eq(2)
      port.recv.should eq(3)
    end

    it "new ports only receive messages sent after creation" do
      ch = CML.mchannel(Int32)

      # Send some messages before creating port
      ch.multicast(1)
      ch.multicast(2)

      # Create port after messages sent
      port = ch.port
      Fiber.yield

      # Send message after port creation
      ch.multicast(3)

      # Port should only receive message 3
      result = port.recv
      result.should eq(3)
    end
  end

  describe "port operations" do
    it "supports recv_evt for use in choose" do
      ch = CML.mchannel(Int32)
      port = ch.port
      Fiber.yield

      # Use choose with timeout
      spawn do
        sleep 10.milliseconds
        ch.multicast(42)
      end

      result = CML.sync(CML.choose(
        CML.wrap(port.recv_evt) { |v| {:msg, v} },
        CML.wrap(CML.timeout(100.milliseconds)) { {:timeout, 0} }
      ))

      result[0].should eq(:msg)
      result[1].should eq(42)
    end

    it "supports copying ports" do
      ch = CML.mchannel(Int32)
      port1 = ch.port
      Fiber.yield

      ch.multicast(1)
      ch.multicast(2)

      # Receive first message on port1
      port1.recv.should eq(1)

      # Copy port1 - should be at same position (after msg 1)
      port2 = port1.copy
      Fiber.yield

      # Send another message
      ch.multicast(3)

      # port1 should get 2 then 3
      port1.recv.should eq(2)
      port1.recv.should eq(3)

      # port2 should also get 2 then 3 (started at same position as port1)
      port2.recv.should eq(2)
      port2.recv.should eq(3)
    end
  end

  describe "different types" do
    it "works with strings" do
      ch = CML.mchannel(String)
      port = ch.port
      Fiber.yield

      ch.multicast("hello")
      ch.multicast("world")

      port.recv.should eq("hello")
      port.recv.should eq("world")
    end

    it "works with tuples" do
      ch = CML::Multicast::Chan(Tuple(Int32, String)).new
      port = ch.port
      Fiber.yield

      ch.multicast({1, "one"})
      ch.multicast({2, "two"})

      port.recv.should eq({1, "one"})
      port.recv.should eq({2, "two"})
    end
  end
end
