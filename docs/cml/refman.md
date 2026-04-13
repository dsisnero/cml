# The Concurrent ML Reference Manual

This document is adapted from the SML/NJ CML documentation (`refman.mldoc`) for
the Crystal CML implementation. It serves as the main reference manual for the
Concurrent ML library, covering both core concepts and library extensions.

## Overview

The Concurrent ML Reference Manual provides comprehensive documentation of:

1.  **Basic Concepts** - Fundamental CML programming principles
2.  **Core CML** - Primary structures for events, threads, and synchronization
3.  **CML Library** - Extended functionality including multicast and tracing

In Crystal, this manual is split across multiple documents for clarity, with
this document serving as a table of contents and integration guide.

## Document Structure

### [Basics](basics.md)

Introduction to CML concepts and porting information.

**Covers**:

*   Event model and synchronization
*   Threads vs fibers in Crystal
*   Garbage collection of threads
*   Porting from older CML versions

### [Core CML Reference](core-cml.md)

Comprehensive reference to core CML structures.

**Includes**:

*   [CML structure](cml.md) - Events, threads, channels, combinators
*   [SyncVar structure](sync-var.md) - IVar, MVar, CVar synchronization variables
*   [Mailbox structure](mailbox.md) - Buffered asynchronous channels
*   [Barrier structure](barrier.md) - Barrier synchronization
*   [OS structure](os.md) - Operating system interface
    *   [OS.IO](os-io.md) - I/O event operations
    *   [OS.Process](os-process.md) - Process operations

### [CML Library Reference](cml-lib.md)

Extended functionality beyond core CML.

**Includes**:

*   [Multicast](multicast.md) - Multicast channels and ports
*   [TraceCML](trace-cml.md) - Debugging and tracing support

## Crystal CML Architecture

Crystal's CML implementation follows the SML/NJ design with adaptations for
Crystal's type system and concurrency model:

### Key Differences from SML/NJ

1.  **Type system**: Generic types `Chan(T)`, `Event(T)` vs SML's `'a chan`,
   `'a event`
2.  **Concurrency model**: Cooperative fibers vs preemptive threads
3.  **Namespace**: Single `CML` module vs multiple structures
4.  **Extensions**: Additional features like `CML.after`, `CML.sleep`,
   `CML.spawn_evt`

### Module Hierarchy

```text
CML (top-level module)
├── Thread          - Thread identification and joining
├── IOEvents        - I/O event operations (not under OS)
├── Socket          - Socket event operations
├── Process         - Process execution events
├── Multicast       - Multicast channels and ports
├── Barrier         - Barrier synchronization
├── Mailbox         - Buffered message queues
├── IVar(T)         - Write-once variables
├── MVar(T)         - Mutable variables
├── CVar(T)         - Condition variables
├── PrimitiveIO     - Low-level I/O polling
├── Tracer          - Tracing configuration
└── Parallel        - Parallel execution contexts
```

## Core Concepts

### Events and Synchronization

Only `CML.sync(evt)` blocks a fiber. Event registration (`poll` method) must
remain non-blocking. This preserves the "one commit" invariant where each
`choose` completes exactly one branch.

```crystal
# Event creation from channel receive
recv_evt = chan.recv_evt

# Synchronization (blocks fiber)
value = CML.sync(recv_evt)
```

### Threads and Fibers

Crystal uses cooperative fibers, not preemptive threads. Use `CML.yield` for
explicit context switching.

```crystal
CML.spawn do
  loop do
    do_work
    CML.yield  # Allow other fibers to run
  end
end
```

### Combinators

Event combinators build complex synchronization patterns:

```crystal
# Choose between events
choice = CML.choose(
  chan1.recv_evt.wrap { |v| :chan1(v) },
  chan2.recv_evt.wrap { |v| :chan2(v) },
  CML.timeout(5.seconds).wrap { :timeout }
)

result = CML.sync(choice)
```

## Porting from SML/NJ

See the [Porting Guide](porting.md) for detailed mapping between SML/NJ CML and
Crystal CML APIs.

## Example: Echo Server

```crystal
def echo_server(chan : Chan(String))
  loop do
    msg = chan.recv_evt.sync
    puts "Echo: #{msg}"
  end
end

def client(chan : Chan(String), id : Int32)
  5.times do |i|
    chan.send_evt("Hello #{id}-#{i}").sync
    CML.sync(CML.timeout(500.milliseconds))
  end
end

chan = CML.chan(String)
CML.spawn { echo_server(chan) }
3.times { |i| CML.spawn { client(chan, i) } }
CML.sync(CML.timeout(3.seconds))
```

## Getting Started

1.  **Read the basics**: [Basics](basics.md) for fundamental concepts
2.  **Explore core API**: [CML structure](cml.md) for event operations
3.  **Learn synchronization**: [SyncVar](sync-var.md) for shared state
4.  **Use extended features**: [CML Library](cml-lib.md) for multicast and
   tracing

## See Also

*   [Crystal CML Manual](../cml_manual.md) - High-level tutorial and examples
*   [SML/NJ CML Documentation](https://www.smlnj.org/doc/) - Original
  documentation
*   [Crystal CML Source Code](../../src/cml/) - Implementation source

---

*Adapted from SML/NJ Concurrent ML Reference Manual version 1.1 (2003-03-10)*
