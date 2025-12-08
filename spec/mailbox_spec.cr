require "spec"
require "../src/cml"
require "../src/cml/mailbox.cr"

# Specs for asynchronous Mailbox in CML
# --------------------------------------
# The Mailbox behaves like an unbounded asynchronous channel:
#   - send never blocks
#   - recv blocks if empty
#   - recv_evt can be used in choose for selective receive
#   - messages are delivered FIFO
#   - cancelled receivers are removed safely

describe CML::Mailbox do
  it "delivers messages in FIFO order" do
    mb = CML::Mailbox(Int32).new

    # send several messages
    3.times { |i| mb.send(i) }

    # recv should get them in order
    results = Array(Int32).new
    3.times { results << mb.recv }

    results.should eq([0, 1, 2])
  end

  it "blocks recv until a message arrives" do
    mb = CML::Mailbox(String).new
    got = Channel(String).new(1)

    spawn do
      msg = mb.recv
      got.send(msg)
    end

    # Give receiver time to block
    sleep 10.milliseconds
    mb.send("hello")

    got.receive.should eq("hello")
  end

  it "never blocks send even with no receivers" do
    mb = CML::Mailbox(Int32).new

    # Should return immediately
    start = Time.monotonic
    mb.send(42)
    elapsed = Time.monotonic - start

    (elapsed < 10.milliseconds).should be_true
  end

  it "works with recv_evt inside select for tagged handling" do
    mb1 = CML::Mailbox(String).new
    mb2 = CML::Mailbox(String).new

    spawn do
      sleep 10.milliseconds
      mb2.send("second")
    end

    # Use choose + wrap to attach handlers to each event, like SML's selective receive
    result = CML.sync(CML.choose(
      CML.wrap(mb1.recv_evt) { |str| str },
      CML.wrap(mb2.recv_evt) { |str| "second: #{str}" },
    ))
    result.should eq("second: second")
  end

  it "supports cancellation of waiting receivers" do
    mb = CML::Mailbox(Int32).new
    timeout_evt = CML.timeout(20.milliseconds)

    evt = CML.choose(
      mb.recv_evt,
      timeout_evt
    )

    # nothing sent → timeout branch wins
    result = CML.sync(evt)
    result.should eq(:timeout)
  end

  it "delivers messages to waiting receivers immediately" do
    mb = CML::Mailbox(Int32).new
    got = Channel(Int32).new(1)

    spawn do
      got.send(mb.recv)
    end

    sleep 5.milliseconds
    mb.send(99)
    got.receive.should eq(99)
  end

  it "poll returns nil when empty and value when available" do
    mb = CML::Mailbox(String).new
    mb.poll.should be_nil

    mb.send("msg")
    mb.poll.should eq("msg")
  end

  it "can handle concurrent senders safely" do
    mb = CML::Mailbox(Int32).new
    results = Channel(Int32).new(100)
    n = 50

    n.times do |i|
      spawn do
        mb.send(i)
      end
    end

    spawn do
      n.times { results.send(mb.recv) }
    end

    out = Array(Int32).new
    n.times { out << results.receive }

    out.sort.should eq((0...n).to_a)
  end
end
