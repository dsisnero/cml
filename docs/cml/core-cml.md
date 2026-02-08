# Core CML Reference

This document is adapted from the SML/NJ CML documentation (`core-cml.mldoc`) for the Crystal CML implementation. It serves as a reference guide to the core CML modules and their APIs.

## Overview

Core CML includes the fundamental structures for concurrent programming:

1.  **CML** - Basic events, threads, channels, and combinators
2.  **SyncVar** - Synchronization variables (IVar, MVar)
3.  **Mailbox** - Asynchronous buffered communication
4.  **Barrier** - Barrier synchronization
5.  **OS** - Operating system interface (file system, processes, I/O)

In Crystal, these are organized into modules and classes within the `CML` namespace.

## Included Modules

### [CML Structure](cml.md)

The core CML module providing:

*   Event type (`Event(T)`) and synchronization (`sync`)
*   Channel operations (`Chan(T)`, `recv_evt`, `send_evt`)
*   Thread creation and management (`spawn`, `spawnc`, `get_tid`)
*   Event combinators (`choose`, `wrap`, `guard`, `with_nack`, `always`)
*   Timeout operations (`timeout`, `at_time`)

### [Synchronization Variables](sync-var.md)

Synchronization variables for shared state:

* **IVar** - Write-once variables (`ivar`, `i_put`, `i_get_evt`)
* **MVar** - Mutable variables (`mvar`, `m_put`, `m_take`)
* **CVar** - Condition variables (`cvar`, `wait_evt`, `signal`, `broadcast`)

### [Mailbox](mailbox.md)

Asynchronous buffered channels:

*   `Mailbox(T)` - Buffered message queue
*   `mailbox` - Creation function
*   `send`/`recv` - Buffered send/receive operations

### [Barrier](barrier.md)

Barrier synchronization for multiple threads:

*   `Barrier` - Synchronization point for N threads
*   `barrier` - Creation function
*   `await` - Wait for all threads to reach barrier

### [OS Interface](os.md)

Operating system abstractions (file system, processes, I/O):

* **OS** - Container structure (maps to Crystal's `CML::OS` module)
* **OS.Process** - Process operations (`CML::OS::Process`)
* **OS.IO** - I/O event operations (`CML::OS::IO`)

## Crystal Namespace Mapping

| SML/NJ Structure | Crystal Location | Description |
|-----------------|------------------|-------------|
| `CML` | `CML` module | Core CML functions |
| `SyncVar` | `CML::IVar(T)`, `CML::MVar(T)` classes | Synchronization variables |
| `Mailbox` | `CML::Mailbox(T)` class | Buffered channels |
| `Barrier` | `CML::Barrier` class | Barrier synchronization |
| `OS` | `CML::OS` module | OS interface container |
| `OS.Process` | `CML::OS::Process` module | Process operations |
| `OS.IO` | `CML::OS::IO` module | I/O event operations |

## Extended Features

Crystal CML includes additional functionality not present in SML/NJ Core CML:

* **Tracing system**: Macro-based tracing with `-Dtrace` flag
* **Thread tools**: `CML::Thread` module with utilities
* **Socket operations**: `CML::Socket` module for network communication
* **RPC framework**: `CML::RPC` module for remote procedure calls
* **Parallel contexts**: `CML::Parallel` for multi-core execution

## API Stability

The Core CML API in Crystal aims to maintain compatibility with SML/NJ semantics while adapting to Crystal's type system and idioms. Breaking changes from SML/NJ are documented in the [Porting Guide](porting.md).

## See Also

*   [Crystal CML Manual](../cml_manual.md) - High-level overview
*   [SML/NJ CML Documentation](https://www.smlnj.org/doc/) - Original documentation
*   [Porting Guide](porting.md) - Porting from SML/NJ to Crystal

---

*Adapted from SML/NJ Core CML Reference version 1.2 (2011-02-18)*
