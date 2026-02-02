require "./spec_helper"

describe CML::PrimitiveIO do
  it "provides a default backend" do
    backend = CML::PrimitiveIO.backend
    backend.should be_a(CML::PrimitiveIO::Backend)
  end

  it "creates read events" do
    reader, writer = IO.pipe
    writer << "test"
    writer.flush

    event = CML::PrimitiveIO.read_evt(reader, 4)
    bytes = CML.sync(event)
    String.new(bytes).should eq("test")
  ensure
    reader.try &.close
    writer.try &.close
  end

  it "creates write events" do
    reader, writer = IO.pipe

    event = CML::PrimitiveIO.write_evt(writer, "test".to_slice)
    bytes_written = CML.sync(event)
    bytes_written.should eq(4)

    writer.close
    data = reader.read_string(4)
    data.should eq("test")
  ensure
    reader.try &.close
    writer.try &.close
  end

  it "creates wait readable events" do
    reader, writer = IO.pipe

    spawn do
      sleep 1.millisecond
      writer << "x"
      writer.flush
    end

    event = CML::PrimitiveIO.wait_readable_evt(reader)
    CML.sync(event).should be_nil

    # Now readable, read should succeed immediately
    byte = reader.read_byte
    byte.should eq('x'.ord)
  ensure
    reader.try &.close
    writer.try &.close
  end

  it "creates wait writable events" do
    reader, writer = IO.pipe
    # Pipe buffer is limited, but should be writable initially
    event = CML::PrimitiveIO.wait_writable_evt(writer)
    CML.sync(event).should be_nil
  ensure
    reader.try &.close
    writer.try &.close
  end

  it "supports EventLoop backend for socket events without stalling" do
    server = begin
      TCPServer.new("127.0.0.1", 0)
    rescue ex : Socket::BindError
      pending!("cannot bind TCP socket in this environment: #{ex.message}")
    end

    CML::PrimitiveIO.backend = CML::PrimitiveIO::EventLoopBackend.new

    port = server.local_address.port
    received = Atomic(Bool).new(false)

    ::spawn do
      accept_result = CML.sync(CML.choose(
        CML.wrap(CML::Socket.accept_evt(server)) { |sock| sock.as(::TCPSocket | Symbol) },
        CML.wrap(CML.timeout(2.seconds)) { :timeout.as(::TCPSocket | Symbol) },
      ))
      socket = case accept_result
               when ::TCPSocket
                 accept_result
               else
                 raise "accept timeout"
               end

      msg_result = CML.sync(CML.choose(
        CML.wrap(CML::Socket.recv_evt(socket, 4)) { |data| data.as(Bytes | Symbol) },
        CML.wrap(CML.timeout(2.seconds)) { :timeout.as(Bytes | Symbol) },
      ))
      msg = case msg_result
            when Bytes
              msg_result
            else
              raise "server recv timeout"
            end

      received.set(String.new(msg) == "ping")
      send_result = CML.sync(CML.choose(
        CML.wrap(CML::Socket.send_evt(socket, "pong".to_slice)) { |count| count.as(Int32 | Symbol) },
        CML.wrap(CML.timeout(2.seconds)) { :timeout.as(Int32 | Symbol) },
      ))
      raise "server send timeout" if send_result == :timeout
      socket.close
    end

    connect_result = CML.sync(CML.choose(
      CML.wrap(CML::Socket.connect_evt("127.0.0.1", port)) { |sock| sock.as(::TCPSocket | Symbol) },
      CML.wrap(CML.timeout(2.seconds)) { :timeout.as(::TCPSocket | Symbol) },
    ))
    client = case connect_result
             when ::TCPSocket
               connect_result
             else
               raise "connect timeout"
             end

    send_result = CML.sync(CML.choose(
      CML.wrap(CML::Socket.send_evt(client, "ping".to_slice)) { |count| count.as(Int32 | Symbol) },
      CML.wrap(CML.timeout(2.seconds)) { :timeout.as(Int32 | Symbol) },
    ))
    raise "client send timeout" if send_result == :timeout

    data_result = CML.sync(CML.choose(
      CML.wrap(CML::Socket.recv_evt(client, 4)) { |bytes| bytes.as(Bytes | Symbol) },
      CML.wrap(CML.timeout(2.seconds)) { :timeout.as(Bytes | Symbol) },
    ))
    data = case data_result
           when Bytes
             data_result
           else
             raise "client recv timeout"
           end

    String.new(data).should eq("pong")
    received.get.should be_true
    client.close
  ensure
    server.close if server
    CML::PrimitiveIO.backend = nil
  end

  it "supports nack cancellation" do
    reader, writer = IO.pipe
    # Create a read event with nack and nack detection
    nack_called = false
    nack_evt = nil
    read_event = CML.with_nack do |nack|
      nack_evt = nack
      CML::PrimitiveIO.read_evt(reader, 4, nack)
    end
    spawn do
      CML.sync(nack_evt.not_nil!)
      nack_called = true
    end
    # Wrap read event to produce nil so it matches timeout type
    wrapped_read = CML.wrap(read_event) { nil }
    timeout_event = CML.timeout(10.milliseconds)

    # Choose between wrapped read and timeout (both Event(Nil))
    event = CML.choose([wrapped_read, timeout_event])

    result = CML.sync(event)
    Fiber.yield # Let nack handler run
    # Timeout should fire first (no data)
    result.should be_nil
    # Nack should be called for the read event
    nack_called.should be_true
  ensure
    reader.try &.close
    writer.try &.close
  end

  {% if flag?(:execution_context) %}
  describe "execution context detection" do
    it "selects appropriate backend for context" do
      # Reset backend cache to force re-selection
      CML::PrimitiveIO.backend = nil

      # Default context (should be Isolated or Concurrent depending on Crystal)
      backend = CML::PrimitiveIO.backend
      backend.should be_a(CML::PrimitiveIO::Backend)

      # Note: We can't easily test Parallel context selection without
      # actually creating a Parallel context, which would require
      # spawning OS threads. The eventloop_compat_spec tests that.
      # This test just ensures the mechanism works in default context.
    end

    it "detects parallel context with flag" do
      # This test requires -Dpreview_mt -Dexecution_context
      # The in_parallel_context? method is private, but we can test
      # indirectly by checking backend selection after resetting cache.
      # However, we cannot call private methods.
      # We'll rely on integration tests in eventloop_compat_spec.
    end
  end
  {% end %}
end
