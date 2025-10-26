# Crystal Concurrent ML (CML)

A minimal, composable, and correct **Concurrent ML runtime for Crystal** —
built from first principles using events, channels, and fibers.

> 💡 *Concurrent ML (CML)* is a message-passing concurrency model introduced by John Reppy.
> It extends synchronous channels with **first-class events** that can be composed, chosen, or canceled safely.

[![Crystal CI](https://img.shields.io/badge/Crystal-1.0+-brightgreen.svg)](https://crystal-lang.org)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

## 1. Overview

This library provides a small but complete CML implementation in pure Crystal.
It adds a higher-level event layer on top of Crystal's built-in channels and fibers.

**Core features:**
- `Event(T)` abstraction for synchronization
- Atomic commit cell (`Pick`) ensuring only one event in a choice succeeds
- `Chan(T)` supporting synchronous rendezvous communication
- Event combinators: `choose`, `wrap`, `guard`, `nack`, `timeout`
- Fully deterministic, non-blocking registration semantics
- Fiber-safe cancellation and cleanup

**Design principles:**
- **One pick, one commit**: Exactly one event in a choice succeeds
- **Zero blocking in registration**: `try_register` never blocks
- **Deterministic behavior**: Predictable regardless of scheduling
- **Memory safe**: No recursion in structs, proper cleanup

---

## 2. Installation

Add this to your `shard.yml`:

```yaml
dependencies:
  cml:
    github: your-username/cml.cr
```

Then run:
```bash
shards install
```

---

## 3. Quick Examples

### Basic Channel Communication

```crystal
require "cml"

# Create a channel for integers
ch = CML::Chan(Int32).new

# Spawn a sender
spawn { CML.sync(ch.send_evt(99)) }

# Receiver waits synchronously
val = CML.sync(ch.recv_evt)
puts val  # => 99
```

### Racing Events with Timeout

```crystal
# Use choose to race a receive against a timeout
evt = CML.choose([
  ch.recv_evt,
  CML.wrap(CML.timeout(1.second)) { |_t| "timeout" }
])
puts CML.sync(evt)  # => "timeout" if no message arrives
```

### Event Composition

```crystal
# Transform event results with wrap
string_evt = CML.wrap(ch.recv_evt) { |x| "Received: #{x}" }

# Defer event creation with guard
lazy_evt = CML.guard { expensive_computation_evt }

# Cleanup on cancellation with nack
safe_evt = CML.nack(ch.recv_evt) { puts "Event was cancelled!" }
```

---

## 4. Core API

### Events
- `CML.sync(evt)` - Synchronize on an event
- `CML.always(value)` - Event that always succeeds
- `CML.never` - Event that never succeeds
- `CML.timeout(duration)` - Time-based event

### Combinators
- `CML.choose(events)` - Race multiple events
- `CML.wrap(evt, &block)` - Transform event result
- `CML.guard(&block)` - Lazy event construction
- `CML.nack(evt, &block)` - Cancellation cleanup

### Channels
- `CML::Chan(T).new` - Create a synchronous channel
- `chan.send_evt(value)` - Send event
- `chan.recv_evt` - Receive event

---

## 5. Advanced Usage

### Nested Choices
```crystal
inner = CML.choose([evt1, evt2])
outer = CML.choose([inner, evt3])
result = CML.sync(outer)
```

### Multiple Concurrent Channels
```crystal
ch1 = CML::Chan(Int32).new
ch2 = CML::Chan(String).new

evt = CML.choose([
  CML.wrap(ch1.recv_evt) { |x| "Number: #{x}" },
  CML.wrap(ch2.recv_evt) { |s| "String: #{s}" }
])
```

### Re-entrant Guards
```crystal
evt = CML.guard do
  if some_condition
    CML.always(:ready)
  else
    CML.timeout(1.second)
  end
end
```

---

## 6. Documentation

- [**Overview & Architecture**](docs/overview.md) - Deep dive into event semantics
- [**API Reference**](docs/api.md) - Complete API documentation
- [**Examples**](examples/) - Working code examples

---

## 7. Running Tests

```bash
crystal spec
```

---

## 8. Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidelines and [AGENTS.md](AGENTS.md) for AI agent contribution rules.

---

## 9. License

MIT License - see [LICENSE](LICENSE) file for details.