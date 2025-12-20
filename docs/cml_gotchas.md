# CML Common Gotchas and Type Mismatches

This document explains common pitfalls and type system issues when working with Crystal CML, especially with the `choose` combinator and event composition.

## 1. Type Mismatches in `choose`

### The Problem

The `CML.choose` combinator requires all events in the array to have the **same return type**. Crystal's type system enforces this at compile time.

**Incorrect Example:**

```crystal
ch1 = CML::Chan(Int32).new
ch2 = CML::Chan(String).new

# ERROR: All events must have the same type
choice = CML.choose([ch1.recv_evt, ch2.recv_evt])  # Type mismatch!
```

**Error Message:**

```text
no overload matches 'CML.choose' with type Array(CML::Event(Int32) | CML::Event(String))
```

### Solution: Use `wrap` to Unify Types

Wrap events to a common supertype (usually `String`, `Symbol`, or a union type).

```crystal
choice = CML.choose([
  CML.wrap(ch1.recv_evt) { |x| x.to_s },
  CML.wrap(ch2.recv_evt) { |s| s }
])
# Both now return String
result = CML.sync(choice)
```

### Alternative: Use Union Types

If you need to preserve the original type information, use a union type:

```crystal
choice = CML.choose([
  CML.wrap(ch1.recv_evt) { |x| {channel: :int_ch, value: x}.as({channel: Symbol, value: Int32 | String}) },
  CML.wrap(ch2.recv_evt) { |s| {channel: :str_ch, value: s}.as({channel: Symbol, value: Int32 | String}) }
])
result = CML.sync(choice)
case result[:channel]
when :int_ch then puts "Got integer: #{result[:value].as(Int32)}"
when :str_ch then puts "Got string: #{result[:value].as(String)}"
end
```

## 2. Event Return Type Inference

### Guard Blocks Must Return Events

The block passed to `CML.guard` must return an `Event(T)`, not the raw value.

**Incorrect:**

```crystal
evt = CML.guard { 42 }  # Returns Int32, not Event(Int32)
```

**Correct:**

```crystal
evt = CML.guard { CML.always(42) }  # Returns Event(Int32)
```

### Wrap Handler Types

`CML.wrap_handler` expects the handler block to return an `Event(T)`, not a raw value.

**Incorrect:**

```crystal
evt = CML.wrap_handler(some_event) { |ex| :error }  # Returns Symbol
```

**Correct:**

```crystal
evt = CML.wrap_handler(some_event) { |ex| CML.always(:error) }  # Returns Event(Symbol)
```

## 3. Channel Type Parameters

### Generic Type Inference

When creating channels, the type parameter must be specified explicitly if Crystal can't infer it:

```crystal
ch = CML::Chan.new  # ERROR: Can't infer type parameter
ch = CML::Chan(Int32).new  # Correct
```

### Type Variance in Crystal

Crystal's generic types are invariant (unlike some other languages). This means `Chan(Dog)` is NOT a subtype of `Chan(Animal)` even if `Dog < Animal`.

```crystal
class Animal; end
class Dog < Animal; end

animal_chan = CML::Chan(Animal).new
dog_chan = CML::Chan(Dog).new

# ERROR: Type mismatch
animal_chan = dog_chan  # Not allowed
```

## 4. with_nack Return Type

### The nack Event

`CML.with_nack` yields a `Event(Nil)` (the nack event) to the block. The block must return an `Event(T)`.

**Correct pattern:**

```crystal
evt = CML.with_nack do |nack|
  # Setup cleanup that runs if event is nacked
  CML.spawn do
    CML.sync(nack)
    cleanup()
  end

  # Return the actual event
  some_operation_evt
end
```

## 5. Timeout Events Return `Nil`

`CML.timeout(duration)` returns an `Event(Nil)`. When used with `choose`, you often need to wrap it to match other event types.

```crystal
ch = CML::Chan(String).new
timeout_evt = CML.timeout(1.second)

choice = CML.choose([
  ch.recv_evt,
  CML.wrap(timeout_evt) { "timeout" }  # Convert Nil to String
])
result = CML.sync(choice)  # Returns String
```

## 6. Socket Event Types

### TCP vs UDP Events

`CML::Socket.recv_evt` returns `Event(Bytes)` for TCP sockets, but `CML::Socket::UDP.recv_evt` returns `Event({Bytes, Socket::IPAddress})`.

```crystal
# TCP
tcp_socket = TCPSocket.new("example.com", 80)
tcp_recv = CML::Socket.recv_evt(tcp_socket, 1024)  # Event(Bytes)

# UDP
udp_socket = UDPSocket.new
udp_recv = CML::Socket::UDP.recv_evt(udp_socket, 1024)  # Event({Bytes, Socket::IPAddress})
```

## 7. Atomic Operations and Thread Safety

### Crystal's Atomic Types

CML uses Crystal's `Atomic` primitives for thread-safe operations. When extending CML, use:

```crystal
@counter = Atomic(Int32).new(0)

def increment
  @counter.add(1)
end

def get_value
  @counter.get
end
```

### Avoid Unsafe State Sharing

Never expose mutable state across fibers without synchronization:

```crystal
class UnsafeCounter
  @value = 0  # UNSAFE: Not atomic

  def increment
    @value += 1  # Race condition!
  end
end
```

## 8. Fiber Yielding and Non-blocking Semantics

### Cooperative Multitasking

Crystal fibers use cooperative multitasking. Long-running computations should yield periodically:

```crystal
def compute_intensive_task
  result = 0
  1_000_000.times do |i|
    result += i
    Fiber.yield if i % 10_000 == 0  # Yield every 10k iterations
  end
  result
end
```

### Event Registration Never Blocks

Remember: Only `CML.sync(evt)` blocks. Event creation and registration should never block.

## 9. Debugging Type Errors

### Common Error Messages

1. **"no overload matches"**: Check that all events in `choose` have the same type.
2. **"expected Event(T), got U"**: Use `CML.always(value)` or `CML.wrap` to convert values to events.
3. **"can't infer type parameter"**: Add explicit type annotations to generic classes.
4. **"undefined method"**: Check that you're calling methods on the right instance (e.g., `chan.send_evt` not `chan.send`).

### Using Crystal's Type Annotations

When in doubt, add explicit type annotations:

```crystal
ch : CML::Chan(Int32) = CML::Chan(Int32).new
evt : CML::Event(String) = CML.wrap(ch.recv_evt) { |x| x.to_s }
```

## 10. Testing Patterns

### Type-Safe Test Helpers

Create helper methods that preserve type safety:

```crystal
def typed_choose(events : Array(CML::Event(T))) : CML::Event(T) forall T
  CML.choose(events)
end

# Now compiler enforces same type
choice = typed_choose([evt1, evt2])  # Both must have same T
```

## Summary

The key to avoiding type issues in CML is:

1. **Unify types in `choose`** using `wrap`
2. **Always return `Event(T)`** from guard and handler blocks
3. **Use explicit type parameters** for generic classes
4. **Understand Crystal's type variance** for channels
5. **Add type annotations** when the compiler complains

When you encounter type errors, break down complex expressions and add temporary variables with explicit types to help the compiler (and yourself) understand what's expected.