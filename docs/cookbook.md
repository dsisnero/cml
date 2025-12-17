# CML Cookbook: Idioms for Concurrent Coordination

This cookbook provides practical patterns and recipes for using the CML library in Crystal. Each idiom demonstrates a common concurrency scenario using CML events, channels, and helpers.

## 1. Timeout with after

```crystal
CML.after(1.second) { puts "Timeout reached!" }
```

## 2. Spawning a worker and waiting for result

```crystal
result_evt = CML.spawn_evt { compute_something() }
CML.sync(result_evt)
```

## 3. Pipeline with channels

```crystal
ch1 = CML::Chan(Int32).new
ch2 = CML::Chan(String).new

CML.after(0.seconds) { ch1.send(42) }
CML.after(0.seconds) { ch2.send("done") }

CML.sync(CML.choose([ch1.recv, ch2.recv]))
```

## 4. Channel-backed streams

```crystal
ch = CML.channel(String)
reader = CML.open_chan_in(ch)
writer = CML.open_chan_out(ch)

CML.after(0.seconds) { CML.sync(CML.write_line_evt(writer, "hello")) }

line = CML.sync(CML.read_line_evt(reader))
puts line # => "hello\n"
```

## 5. Racing IO vs timeout

```crystal
io = IO::Memory.new("hello\nworld")

result = CML.sync(CML.choose([
  CML.wrap(CML.read_line_evt(io)) { |ln| ln },
  CML.wrap(CML.timeout(10.milliseconds)) { "timed out" },
]))
puts result
```

## 6. TCP/UDP helpers with cancellation

```crystal
# TCP connect with timeout
sock = CML.sync(CML.choose([
  CML.connect_evt("example.com", 80),
  CML.wrap(CML.timeout(100.milliseconds)) { nil },
]))

if sock
  CML.sync(CML.socket_send_evt(sock, "ping".to_slice))
  sock.close
end

# UDP send/recv (bind may be restricted in some environments)
udp = UDPSocket.new
udp.bind("127.0.0.1", 12345)
CML.sync(CML.udp_send_evt(udp, "hello".to_slice, "127.0.0.1", 12345))
```

## 4. Chat room with multiple senders/receivers

See `examples/chat_demo.cr` for a full example.

## 5. Timeout worker pattern

```crystal
result = CML.sync(CML.with_timeout(long_running_evt, 2.seconds))
if result[1] == :timeout
  puts "Worker timed out!"
else
  puts "Worker finished: #{result[0]}"
end
```

---

For more, see the `examples/` directory and the README quickstart.
