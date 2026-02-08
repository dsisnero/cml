# Porting old programs

This document is adapted from the SML/NJ CML documentation (`porting.mldoc`) for the Crystal CML implementation. It describes changes from older versions of CML and provides guidance for porting SML/NJ CML programs to Crystal.

## Overview

The Crystal CML implementation is a fresh implementation inspired by SML/NJ CML, not a direct port. As such, many API differences exist beyond simple name changes. This guide covers:

1.  **SML/NJ CML 0.9.8 to 1.0+ changes** (from original documentation)
2.  **SML/NJ CML to Crystal CML mapping** (additional guidance)
3.  **Crystal-specific extensions and idioms**

## Namespace Differences

In Crystal, all CML functionality is in the `CML` module (or submodules like `CML::Thread`, `CML::IOEvents`, etc.). This differs from SML/NJ where structures like `CML`, `SyncVar`, `Mailbox`, etc. are separate.

## Backwards compatibility modules

SML/NJ CML provided two backwards compatibility modules (`CML98` and `CML98Ext`) to ease transition from version 0.9.8. Crystal does not provide these modules, but the mapping tables below can help translate old code.

## Name changes (SML/NJ 0.9.8 to 1.0+)

The following table shows name changes from SML/NJ CML 0.9.8 to 1.0+ (as documented in the original porting guide):

| Old name (0.9.8) | New name (1.0+) | Crystal equivalent |
|------------------|-----------------|-------------------|
| `accept` | `CML.recv` | `Chan(T)#recv_evt` |
| `receive` | `CML.recvEvt` | `Chan(T)#recv_evt` |
| `transmit` | `CML.sendEvt` | `Chan(T)#send_evt` |
| `timout` | `CML.timeOutEvt` | `CML.timeout` |
| `waitUntil` | `CML.atTimeEvt` | `CML.at_time` |
| `threadWait` | `CML.joinEvt` | `CML::Thread#join_evt` |
| `sameThread` | `CML.sameTid` | `CML::Thread.same?` |

**Notes**:

*   Crystal uses `_evt` suffix for event-returning operations (e.g., `recv_evt`, `send_evt`)
*   Timeout functions: `CML.timeout(duration)` returns an event that becomes enabled after the duration
*   The `at_time` function takes a `Time` object rather than a timeout value

## Input/output

Significant changes occurred in SML/NJ CML 0.9.8 to 1.0+ regarding I/O operations. The old `CIO` structure provided event-valued versions of SML/NJ's `IO` signature. This was replaced with Basis Library-compatible interfaces.

In Crystal, I/O events are provided through the `CML::IOEvents` module:

```crystal
# File descriptor read event
CML.read_evt(fd : IO::FileDescriptor) : Event(String)

# File descriptor write event
CML.write_evt(fd : IO::FileDescriptor, data : String) : Event(Int32)

# Socket accept event
CML::Socket.accept_evt(socket : Socket) : Event(Socket)
```

## Condition variables

Condition variables from SML/NJ CML are represented as `CML::CVar(T)` in Crystal. The API is similar but uses Crystal naming conventions:

```crystal
# Create a condition variable
cvar = CML.cvar

# Wait for condition (returns event)
wait_evt = cvar.wait_evt

# Signal one waiting thread
cvar.signal

# Signal all waiting threads
cvar.broadcast
```

## Polling

SML/NJ CML 0.9.8 had a `poll` operation providing non-blocking `sync`. This was eliminated in 1.0+ in favor of non-blocking operations on basic communication types.

Crystal provides non-blocking variants for many operations:

```crystal
# Non-blocking channel receive
chan.recv_evt(nowait: true)

# Non-blocking channel send
chan.send_evt(value, nowait: true)

# Non-blocking MVar put/take
mvar.put_evt(value, nowait: true)
mvar.take_evt(nowait: true)
```

## Porting from SML/NJ CML to Crystal CML

### General Principles

1.  **Type signatures**: Convert SML type parameters to Crystal generics
    *   `'a chan` → `Chan(T)`
    *   `'a event` → `Event(T)`
    *   `'a -> 'b` → `A -> B`

2.  **Naming conventions**: Use snake_case for method names
    *   `sameChannel` → `same_channel`
    *   `iGetEvt` → `i_get_evt`

3.  **Namespace**: Prefix with `CML.` or use appropriate submodule
    *   `spawn` → `CML.spawn`
    *   `Mailbox.mailbox` → `CML.mailbox`

4.  **Threads vs fibers**: Crystal uses cooperative fibers; explicit yielding may be needed with `CML.yield`

### Common API Mappings

| SML/NJ CML | Crystal CML | Notes |
|------------|-------------|-------|
| `CML.spawn` | `CML.spawn` | Same name, but takes a block |
| `CML.spawnc` | `CML.spawnc` | Takes argument and block |
| `CML.recv` | `chan.recv_evt` | Event-returning version |
| `CML.send` | `chan.send_evt` | Event-returning version |
| `CML.choose` | `CML.choose` | Macro with varargs support |
| `CML.wrap` | `CML.wrap` | Same name |
| `CML.guard` | `CML.guard` | Same name |
| `CML.withNack` | `CML.with_nack` | Snake case |
| `CML.alwaysEvt` | `CML.always` | Shorter name |
| `SyncVar.iVar` | `CML.ivar` | Function, not structure |
| `SyncVar.mVar` | `CML.mvar` | Function, not structure |
| `Mailbox.mailbox` | `CML.mailbox` | Function, returns `Mailbox(T)` |
| `Barrier.barrier` | `CML.barrier` | Function, returns `Barrier` |
| `Multicast.mChannel` | `CML.mchannel` | Function, returns `MChan(T)` |

### Missing Features

Some SML/NJ CML features are not present in Crystal CML:

* **`poll` operation**: Use non-blocking events instead
* **`CIO` structure**: Use `CML::IOEvents` module
* **`CML98`/`CML98Ext` modules**: Not needed for Crystal

### Extended Features

Crystal CML includes extensions not in SML/NJ:

*   `CML.after(duration, &block)` - Timeout with block execution
*   `CML.sleep(duration)` - Convenience sleep function
*   `CML.spawn_evt(&block)` - Event that spawns a thread
*   `CML.nack(evt, &block)` - Add nack handler to existing event
*   Macro-based tracing system (`-Dtrace` flag)

## Example: Porting a Simple Program

**SML/NJ CML**:

```sml
fun producer (ch : int chan) = let
  fun loop n = (CML.send (ch, n); loop (n+1))
in
  loop 0
end

fun consumer (ch : int chan) = let
  fun loop () = (print (Int.toString (CML.recv ch) ^ "\n"); loop ())
in
  loop ()
end

val ch = CML.channel ()
val _ = CML.spawn (fn () => producer ch)
val _ = CML.spawn (fn () => consumer ch)
```

**Crystal CML**:

```crystal
def producer(ch : Chan(Int32))
  n = 0
  loop do
    ch.send_evt(n).sync
    n += 1
  end
end

def consumer(ch : Chan(Int32))
  loop do
    value = ch.recv_evt.sync
    puts value
  end
end

ch = CML.chan(Int32)
CML.spawn { producer(ch) }
CML.spawn { consumer(ch) }
```

## See Also

*   [CML documentation](cml.md) - Core CML structure
*   [Crystal CML Manual](../cml_manual.md) - Crystal-specific overview
*   [SML/NJ CML Documentation](https://www.smlnj.org/doc/) - Original documentation

---

*Adapted from SML/NJ Porting documentation version 1.1 (2003-03-10)*
