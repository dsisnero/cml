# CML Library Reference

This document is adapted from the SML/NJ CML documentation (`cml-lib.mldoc`) for
the Crystal CML implementation. The CML Library includes extended functionality
beyond core CML, organized into substructures.

## Overview

The CML Library provides additional concurrency abstractions and utilities:

1.  **Multicast** - Multicast channels and ports for one-to-many communication
2.  **TraceCML** - Debugging support with trace output and thread monitoring

In Crystal, these are implemented as separate modules within the `CML`
namespace.

## Included Modules

### [Multicast](multicast.md)

Multicast channels (`MChan(T)`) allow one sender to multiple receivers:

```crystal
# Create a multicast channel
mch = CML.mchannel

# Create a port for receiving
port = mch.port

# Send to all ports
mch.send("hello")

# Receive from a specific port
msg = port.recv_evt.sync
```

Key features:

* **Multiple ports**: Each port receives all messages sent to the channel
* **Dynamic membership**: Ports can be created and garbage collected
* **Efficiency**: Single sender, multiple receivers with copying

### [TraceCML](trace-cml.md)

Debugging and tracing support:

```crystal
# Enable tracing at compile time: crystal build -Dtrace

# Set output destination
CML::Tracer.set_output(File.open("trace.log", "w"))

# Filter by tag
CML::Tracer.set_filter_tags(["chan", "event"])

# Trace an operation
CML.trace "Chan.send", value, tag: "chan"
```

Key features:

* **Zero overhead when disabled**: Compiled out without `-Dtrace`
* **Filtering**: By tag, event type, or fiber
* **Thread-safe output**: Concurrent tracing supported

## Namespace Mapping

| SML/NJ Structure | Crystal Location | Description |
|-----------------|------------------|-------------|
| `Multicast` | `CML::Multicast` module | Multicast channels and ports |
| `TraceCML` | `CML::Tracer` class + `CML.trace` macro | Tracing and debugging |
| CML Library overall | `CML` module extensions | Additional functionality |

## Additional Crystal Library Features

Beyond the SML/NJ CML Library, Crystal includes several extended modules:

### Thread Tools (`CML::Thread`)

```crystal
# Get current thread ID
tid = CML.get_tid

# Check if two IDs refer to same thread
same = CML::Thread.same?(tid1, tid2)

# Wait for thread termination
CML::Thread.join_evt(tid).sync
```

### IO Events (`CML::IOEvents`)

```crystal
# Read line event
line_evt = CML.read_line_evt(STDIN)

# Write event
bytes_written_evt = CML.write_evt(STDOUT, "data".to_slice)

# Flush event
flush_evt = CML.flush_evt(io)
```

### Socket Operations (`CML::Socket`)

```crystal
# Accept connection event
accept_evt = CML::Socket.accept_evt(socket)

# Connect event
connect_evt = CML::Socket.connect_evt(host, port)

# Receive/transmit events
recv_evt = CML::Socket.recv_evt(socket, buffer)
send_evt = CML::Socket.send_evt(socket, data)
```

### Process Operations (`CML::Process`)

```crystal
# Execute system command as event
status_evt = CML::Process.system_evt("ls -la")

# Synchronous version
status = CML::Process.system("echo hello")
```

### Parallel Execution (`CML::Parallel`)

```crystal
# Execute in parallel across multiple cores
results = CML::Parallel.map(1..100) do |n|
  compute(n)
end
```

## Library Design Principles

Crystal CML Library follows these principles:

1.  **Composability**: Library components work together seamlessly
2.  **Minimal dependencies**: No external dependencies beyond Crystal stdlib
3.  **Idiomatic Crystal**: Follows Crystal naming conventions and type system
4.  **Zero-cost abstractions**: Tracing compiles out when disabled
5.  **Thread safety**: All operations safe for concurrent use

## Porting Notes

When using the CML Library in Crystal:

1.  **Multicast**: API similar to SML/NJ but with Crystal naming
2.  **TraceCML**: Different design (macro-based vs module-based)
3.  **Extended features**: Many additional utilities not in SML/NJ

## Example: Multicast Server

```crystal
# Create multicast channel for announcements
announce = CML.mchannel(String)

# Create ports for clients
client1 = announce.port
client2 = announce.port

# Server sends announcements
CML.spawn do
  loop do
    CML.sync(CML.timeout(1.second))
    announce.send("Time: #{Time.utc}")
  end
end

# Clients receive announcements
CML.spawn do
  loop do
    msg = client1.recv_evt.sync
    puts "Client1: #{msg}"
  end
end
```

## See Also

*   [Multicast Documentation](multicast.md) - Multicast channels and ports
*   [TraceCML Documentation](trace-cml.md) - Tracing and debugging
*   [Core CML Reference](core-cml.md) - Core CML structures
*   [Crystal CML Manual](../cml_manual.md) - High-level overview

---

*Adapted from SML/NJ CML Library Reference version 1.1 (2003-03-10)*
