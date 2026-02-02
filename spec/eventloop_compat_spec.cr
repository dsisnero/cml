{% skip_file unless flag?(:execution_context) %}
require "./spec_helper"
require "fiber/execution_context"

describe "CML EventLoop Compatibility" do
  it "works in Parallel context with multiple threads" do
    context = Fiber::ExecutionContext::Parallel.new("test", maximum: 4)
    done = Channel(Nil).new
    context.spawn do
      # Simple CML IO operation
      reader, writer = IO.pipe

      spawn do
        writer << "test"
        writer.flush
        writer.close
      end

      bytes = CML.sync(CML.read_evt(reader, 4))
      String.new(bytes).should eq("test")
    ensure
      reader.try &.close
      writer.try &.close
      done.send(nil)
    end
    done.receive
  end

  it "works in Isolated context" do
    context = Fiber::ExecutionContext::Isolated.new("test") do
      reader, writer = IO.pipe

      spawn do
        writer << "test"
        writer.flush
        writer.close
      end

      bytes = CML.sync(CML.read_evt(reader, 4))
      String.new(bytes).should eq("test")
    ensure
      reader.try &.close
      writer.try &.close
    end
    context.wait
  end

  it "mixes CML and Crystal async operations" do
    reader, writer = IO.pipe

    # Write using Crystal blocking IO
    spawn do
      writer << "test"
      writer.flush
      writer.close
    end

    # Read using CML event
    bytes = CML.sync(CML.read_evt(reader, 4))
    String.new(bytes).should eq("test")
  ensure
    reader.try &.close
    writer.try &.close
  end

  it "handles cross-context channel communication" do
    # Create a channel
    ch = CML::Chan(Int32).new

    # Use a Crystal channel to coordinate completion
    sender_done = Channel(Nil).new
    receiver_done = Channel(Nil).new

    # Run sender in Parallel context
    sender_context = Fiber::ExecutionContext::Parallel.new("sender", maximum: 2)
    sender_context.spawn do
      CML.sync(ch.send_evt(42))
      sender_done.send(nil)
    end

    # Run receiver in Isolated context
    receiver_context = Fiber::ExecutionContext::Isolated.new("receiver") do
      value = CML.sync(ch.recv_evt)
      value.should eq(42)
      receiver_done.send(nil)
    end

    # Wait for both to complete
    sender_done.receive
    receiver_done.receive
    receiver_context.wait
  end

  describe "Interference testing" do
    it "mixes CML.read_evt and Crystal io.gets on same IO object" do
      reader, writer = IO.pipe

      # Write multiple lines
      writer.puts "line1"
      writer.puts "line2"
      writer.flush

      # Read first line with Crystal io.gets (explicitly without chomp to match CML behavior)
      line1 = reader.gets(chomp: false)
      line1.should eq("line1\n")

      # Read second line with CML.read_line_evt
      line2 = CML.sync(CML.read_line_evt(reader))
      line2.should eq("line2\n")
    ensure
      reader.try &.close
      writer.try &.close
    end

    it "performs concurrent CML.write_evt and Crystal io.print" do
      reader, writer = IO.pipe

      # Use channels to wait for completion
      cml_done = Channel(Nil).new
      crystal_done = Channel(Nil).new

      # Write with CML
      spawn do
        CML.sync(CML.write_evt(writer, "CML ".to_slice))
        cml_done.send(nil)
      end
      # Write with Crystal
      spawn do
        writer.print("Crystal")
        writer.flush
        crystal_done.send(nil)
      end

      # Wait for both writes to complete
      cml_done.receive
      crystal_done.receive
      writer.close

      # Read all data
      data = reader.gets_to_end
      # Both strings should appear (order non-deterministic)
      data.should contain("CML")
      data.should contain("Crystal")
    ensure
      reader.try &.close
      writer.try &.close
    end

    it "handles cancellation timing with nack vs EventLoop cleanup" do
      # Use a pipe with a read that will be cancelled
      reader, writer = IO.pipe

      # Create a choose between read_evt and timeout with nack
      read_event = CML.read_evt(reader, 4)
      timeout_event = CML.timeout(10.milliseconds)

      # Wrap read_event with nack handler
      nack_called = false
      read_event_with_nack = CML.with_nack do |nack_evt|
        spawn do
          CML.sync(nack_evt)
          nack_called = true
        end
        read_event
      end

      # Wrap to common type Bytes | Nil
      read_event_wrapped = CML.wrap(read_event_with_nack) { |bytes| bytes.as(Bytes | Nil) }
      timeout_event_wrapped = CML.wrap(timeout_event) { |nil_val| nil_val.as(Bytes | Nil) }

      event = CML.choose([read_event_wrapped, timeout_event_wrapped])

      # No data will be written, timeout should fire
      result = CML.sync(event)
      Fiber.yield # Let nack handler run
      # Result should be the timeout (nil) because read never completes
      result.should be_nil
      # Nack should be called for the read event
      nack_called.should be_true
    ensure
      reader.try &.close
      writer.try &.close
    end

    pending "memory usage under 1000 concurrent IO operations" do
      # This is a performance benchmark, can be implemented later
    end
  end

{% if false %}
  describe "Thread safety stress tests" do
    it "handles concurrent reads from same IO in Parallel context" do
      reader, writer = IO.pipe
      lines = 10.times.map { |i| "line#{i}" }.to_a
      # Write all lines
      lines.each { |line| writer.puts(line) }
      writer.flush
      writer.close

      # Create Parallel context with 4 threads
      context = Fiber::ExecutionContext::Parallel.new("concurrent_read", maximum: 4)
      results = Channel(String?).new(lines.size)

      lines.size.times do
        context.spawn do
          # Each fiber reads a line using CML
          line = CML.sync(CML.read_line_evt(reader))
          results.send(line)
        end
      end

      # Collect results
      received = Array(String?).new(lines.size)
      lines.size.times { received << results.receive }
      received = received.compact.sort
      expected = lines.map { |line| "#{line}\n" }.sort
      received.should eq(expected)
    ensure
      reader.try &.close
      writer.try &.close
    end

    it "handles concurrent writes to same IO in Parallel context" do
      reader, writer = IO.pipe
      messages = 10.times.map { |i| "msg#{i}" }.to_a
      context = Fiber::ExecutionContext::Parallel.new("concurrent_write", maximum: 4)
      done = Channel(Nil).new(messages.size)

      messages.each do |msg|
        context.spawn do
          CML.sync(CML.write_evt(writer, msg.to_slice))
          done.send(nil)
        end
      end

      messages.size.times { done.receive }
      writer.close

      # Read all data
      data = reader.gets_to_end
      messages.each do |msg|
        data.should contain(msg)
      end
    ensure
      reader.try &.close
      writer.try &.close
    end

    it "propagates IO errors across threads" do
      reader, writer = IO.pipe
      writer.close
      # After writer close, reader will get EOF (nil)
      context = Fiber::ExecutionContext::Parallel.new("error_prop", maximum: 2)
      result = Channel(String?).new(1)
      context.spawn do
        line = CML.sync(CML.read_line_evt(reader))
        result.send(line)
      end
      received = result.receive
      received.should be_nil  # EOF
    ensure
      reader.try &.close
      writer.try &.close
    end

    it "handles cancellation with nack across threads" do
      reader, writer = IO.pipe
      context = Fiber::ExecutionContext::Parallel.new("cancel_test", maximum: 2)
      cancelled = Channel(Bool).new(1)

      # Create a choose between read and timeout with nack
      read_event = CML.read_evt(reader, 4)
      timeout_event = CML.timeout(10.milliseconds)

      nack_called = false
      read_event_with_nack = CML.with_nack do |nack_evt|
        spawn do
          CML.sync(nack_evt)
          nack_called = true
        end
        read_event
      end

      read_event_wrapped = CML.wrap(read_event_with_nack) { |bytes| bytes.as(Bytes | Nil) }
      timeout_event_wrapped = CML.wrap(timeout_event) { |nil_val| nil_val.as(Bytes | Nil) }

      event = CML.choose([read_event_wrapped, timeout_event_wrapped])

      context.spawn do
        result = CML.sync(event)
        # Timeout should win because no data written
        cancelled.send(result.nil?)
      end

      cancelled_result = cancelled.receive
      cancelled_result.should be_true
      nack_called.should be_true
    ensure
      reader.try &.close
      writer.try &.close
    end
  end
{% end %}
end
