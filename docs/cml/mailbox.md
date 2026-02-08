# The Mailbox structure

This document is adapted from the SML/NJ CML documentation (`mailbox.mldoc`) for the Crystal CML implementation.

## Overview

The `Mailbox` structure provides buffered asynchronous channels, which we call mailboxes. Unlike synchronous channels (`Chan`), send operations are non-blocking (producer can always enqueue). Receive operations block until a message is available.

In Crystal, mailboxes are implemented as `CML::Mailbox(T)` class. Module functions are available via `CML.mailbox`, `CML.same_mailbox`, etc.

## Type `Mailbox(T)`

**SML**: `type 'a mbox`

**Crystal**: `class CML::Mailbox(T)`

**Description**:
This is the type constructor for a mailbox. A mailbox is an unbounded, buffered communication channel.

### `mailbox`

**SML signature**: `val mailbox : unit -> 'a mbox`

**Crystal equivalent**:

```crystal
def self.mailbox(type : T.class) : Mailbox(T) forall T
```

**Description**:
Creates a new mailbox.

**Prototype**:

```crystal
mailbox(Int32)  # returns Mailbox(Int32)
```

### `same_mailbox`

**SML signature**: `val sameMailbox : ('a mbox * 'a mbox) -> bool`

**Crystal equivalent**:

```crystal
def self.same_mailbox(m1 : Mailbox(T), m2 : Mailbox(T)) : Bool forall T
# Also instance method:
def same?(other : Mailbox(T)) : Bool
```

**Description**:
Returns `true` if `mb1` and `mb2` are the same mailbox.

**Prototype**:

```crystal
same_mailbox(mb1, mb2)
mb1.same?(mb2)
```

### `send`

**SML signature**: `val send : ('a mbox * 'a) -> unit`

**Crystal equivalent**:

```crystal
# Instance method on Mailbox(T)
def send(value : T) : Nil
```

**Description**:
Sends the message `msg` to the mailbox `mb`. Note that unlike `CML.send` (on channels), this is a non-blocking operation.

**Prototype**:

```crystal
mb.send(msg)
```

### `recv`

**SML signature**: `val recv : 'a mbox -> 'a`

**Crystal equivalent**:

```crystal
# Instance method on Mailbox(T)
def recv : T
```

**Description**:
Receives the next message from the mailbox `mb`. If the mailbox is empty, then this blocks the calling thread until there is a message available.

**Prototype**:

```crystal
mb.recv
```

### `recv_evt`

**SML signature**: `val recvEvt : 'a mbox -> 'a event`

**Crystal equivalent**:

```crystal
# Instance method on Mailbox(T)
def recv_evt : Event(T)
```

**Description**:
Returns the event value that represents the `recv` operation on `mb`.

**Prototype**:

```crystal
mb.recv_evt
```

### `recv_poll`

**SML signature**: `val recvPoll : 'a mbox -> 'a option`

**Crystal equivalent**:

```crystal
# Instance method on Mailbox(T)
def recv_poll : T?
```

**Description**:
This is the non-blocking version of `recv`. If the corresponding blocking form would block (because the mailbox is empty), then this returns `nil`, otherwise it returns the received message.

**Prototype**:

```crystal
mb.recv_poll
```

## Additional Crystal Methods

The Crystal implementation includes additional methods not present in SML/NJ:

### `reset`

```crystal
def reset : Nil
```

Resets the mailbox to its initial state, clearing any pending messages and waiting receivers.

## Usage Notes

Mailbox buffers are unbounded, which means that there is no flow control to prevent a producer from greatly outstripping a consumer, and thus exhausting memory. In situations where there is no natural limit to the rate of `send` operations, it is recommended that the synchronous channels from the `CML` structure be used instead.

## See Also

*   [SML/NJ Mailbox documentation](https://www.smlnj.org/doc/) (original)
*   [CML documentation](cml.md) (core CML structure)
*   [SyncVar documentation](sync-var.md) (synchronization variables)
*   [Crystal CML Manual](../cml_manual.md) (Crystal-specific overview)

---

*Adapted from SML/NJ Mailbox documentation version 1.1 (2003-03-10)*
