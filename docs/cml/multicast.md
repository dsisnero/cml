# The Multicast structure

This document is adapted from the SML/NJ CML documentation (`multicast.mldoc`)
for the Crystal CML implementation.

## Overview

Multicast channels provide a mechanism for broadcasting a stream of messages to
a collection of threads. Threads receive multicast messages via an *output
port*; each port receives its own copy of every message sent since the port was
created. Multicast channels are particularly useful for communicating with a
dynamically varying group of threads, since the sender does not need to know how
many threads are listening.

In Crystal, multicast functionality is in the `CML::Multicast` module. The main
types are `CML::Multicast::Chan(T)` (multicast channel) and
`CML::Multicast::Port(T)` (output port). Module functions are available via
`CML.mchannel` and `CML.multicast`.

## Types

### Event Type

**SML**: `type 'a event = 'a CML.event`

**Crystal**: `CML::Event(T)` (same as core CML events)

**Description**: Event type for multicast operations. This is the same event
type used throughout CML.

### `Chan(T)` (Multicast Channel)

**SML**: `type 'a mchan`

**Crystal**: `class CML::Multicast::Chan(T)`

**Description**:
This is the type constructor for asynchronous multicast channels.

### `Port(T)` (Output Port)

**SML**: `type 'a port`

**Crystal**: `class CML::Multicast::Port(T)`

**Description**: This is the type constructor for output ports on an
asynchronous multicast channel.

## Functions

### `mchannel`

**SML signature**: `val mChannel : unit -> 'a mchan`

**Crystal equivalent**:

```crystal
def self.mchannel(type : T.class) : Multicast::Chan(T) forall T
```

**Description**:
Creates a new multicast channel.

**Prototype**:

```crystal
mc = CML.mchannel(Int32)  # returns Multicast::Chan(Int32)
```

### `port`

**SML signature**: `val port : 'a mchan -> 'a port`

**Crystal equivalent**:

```crystal
# Instance method on Multicast::Chan(T)
def port : Port(T)
```

**Description**: Creates a new output port on the channel `mc`. The port
receives those messages sent after it is created.

**Prototype**:

```crystal
port = mc.port
```

### `copy`

**SML signature**: `val copy : 'a port -> 'a port`

**Crystal equivalent**:

```crystal
# Instance method on Port(T)
def copy : Port(T)
```

**Description**: Creates a new output port on a channel that has the same state
as the port `p`. I.e., the stream of messages seen on the two ports will be the
same. This is useful when two threads need to see the same stream of messages.

**Note**: If two (or more) independent threads are reading from `p` at the time
that `copy` operation is performed, then it may not be accurate.

**Prototype**:

```crystal
port_copy = port.copy
```

### `recv`

**SML signature**: `val recv : 'a port -> 'a`

**Crystal equivalent**:

```crystal
# Instance method on Port(T)
def recv : T
```

**Description**: Gets the next message from the port `p`. The calling thread is
blocked until there is a message available.

**Prototype**:

```crystal
msg = port.recv
```

### `recv_evt`

**SML signature**: `val recvEvt : 'a port -> 'a event`

**Crystal equivalent**:

```crystal
# Instance method on Port(T)
def recv_evt : Event(T)
```

**Description**:
Creates an event value that represents the `recv` operation on the port `p`.

**Prototype**:

```crystal
port.recv_evt
```

### `multicast`

**SML signature**: `val multicast : ('a mchan * 'a) -> unit`

**Crystal equivalent**:

```crystal
# Instance method on Multicast::Chan(T)
def multicast(value : T) : Nil

# Module function:
def self.multicast(mc : Multicast::Chan(T), value : T) : Nil forall T
```

**Description**: Multicasts the value `value` on the channel `mc`. This is a
nonblocking operation.

**Prototype**:

```crystal
mc.multicast(msg)
# or
CML.multicast(mc, msg)
```

## Implementation Details

The Crystal implementation uses a chain of `IVar` (write-once variables) to
represent the message stream. Each port has a "tee" fiber that forwards messages
from the chain to the port's output channel. This design ensures:

1.  **Asynchronous sending**: `multicast` returns immediately
2.  **Independent streams**: Each port maintains its own position in the message
   stream
3.  **Dynamic membership**: Ports can be created and destroyed at any time
4.  **Fairness**: Messages are delivered to all ports in FIFO order

## Example

```crystal
# Create a multicast channel
mc = CML.mchannel(String)

# Create two ports
port1 = mc.port
port2 = mc.port

# Spawn receivers
CML.spawn do
  loop do
    msg = port1.recv
    puts "Port 1 received: #{msg}"
  end
end

CML.spawn do
  loop do
    msg = port2.recv
    puts "Port 2 received: #{msg}"
  end
end

# Send messages
mc.multicast("Hello")
mc.multicast("World")

# Create a copy of port1 at the same position
port1_copy = port1.copy
```

## See Also

*   [SML/NJ Multicast documentation](https://www.smlnj.org/doc/) (original)
*   [CML documentation](cml.md) (core CML structure)
*   [SyncVar documentation](sync-var.md) (synchronization variables, used in
  implementation)
*   [Mailbox documentation](mailbox.md) (asynchronous channels)
*   [Crystal CML Manual](../cml_manual.md) (Crystal-specific overview)

---

*Adapted from SML/NJ Multicast documentation version 1.0 (1997-01-29)*
