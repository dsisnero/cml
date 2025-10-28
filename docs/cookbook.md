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
