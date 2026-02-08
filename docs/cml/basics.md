# Basics

This document is adapted from the SML/NJ CML documentation (`basics.mldoc`) for the Crystal CML implementation.

## Overview

The Basics document covers fundamental concepts of CML programming. In the SML/NJ documentation, this file primarily includes porting information for older CML versions.

For Crystal CML basics, see the [Crystal CML Manual](../cml_manual.md) which covers:

* **Event model**: First-class events (`Event(T)`) representing synchronous operations
* **Thread identity**: `CML::Thread::Id` values for thread identification and joining
* **Channels**: Rendezvous channels (`Chan(T)`) for one-to-one communication
* **Combinators**: `wrap`, `guard`, `choose`, `with_nack`, `timeout`, `always`
* **Synchronization variables**: `IVar`, `MVar`, `CVar`, `Mailbox`, `Barrier`
* **Extended subsystems**: Multicast, IO, Socket, Process, Thread tools, RPC

## Key Concepts

### Events and Synchronization

Only `CML.sync(evt)` blocks a fiber. Event registration must remain non-blocking. This preserves the "one commit" invariant where each `choose` completes exactly one branch.

### Threads and Fibers

Crystal CML uses cooperative fibers rather than preemptive threads. The scheduling is cooperative, meaning threads must explicitly yield or block on synchronization points. Use `CML.yield` for explicit context switching.

### Garbage Collection

Threads that terminate are automatically garbage collected. The `join_evt` mechanism allows waiting for thread termination without preventing garbage collection.

## Porting Information

For information about porting from older versions of CML (specifically SML/NJ CML 0.9.8), see the [Porting Guide](porting.md).

## See Also

*   [SML/NJ Basics documentation](https://www.smlnj.org/doc/) (original)
*   [CML documentation](cml.md) (core CML structure)
*   [Crystal CML Manual](../cml_manual.md) (Crystal-specific overview)
*   [Porting Guide](porting.md) (porting from older CML versions)

---

*Adapted from SML/NJ Basics documentation version 1.0 (1997-01-30)*
