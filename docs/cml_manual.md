# Crystal CML Manual (SML/NJ parity)

This document mirrors the structure and level of detail of the SML/NJ CML library docs, adapted to the Crystal port in this repository. It summarizes the API, naming, and semantics provided by our implementation.

## Overview

- **Concurrency model**: First-class events (`Event(T)`) representing synchronous operations. Only `CML.sync(evt)` blocks a fiber. Event registration must remain non-blocking.
- **Thread identity**: `CML::Thread::Id` values are unique and totally ordered. Use them for joins and ordering, not for equality by object identity.
- **Channels**: Rendezvous channels `CML::Chan(T)` for one-to-one communication.
- **Combinators**: `wrap`, `guard`, `choose`, `with_nack`, `timeout`, `always` preserve the “one commit” invariant.
- **Sync vars**: `IVar` (write-once), `MVar` (mutable slot), `CVar` (condition variable), plus `Mailbox` and `Barrier` helpers.
- **Extended subsystems**: Multicast, IO, Socket, Process, Thread tools, RPC, Linda all mirror the SML/NJ surface where possible, but are namespaced for clarity.

## Core CML

- Threads:
  - `CML.spawn { ... }`, `CML.spawnc(arg) { |a| ... }` → `Thread::Id`
  - `CML.join_evt(tid)`, `CML.exit`, `CML.yield`
  - `CML.get_tid`, `CML.same_tid`, `CML.compare_tid`, `CML.hash_tid`, `CML.tid_to_string`
  - `CML::Thread::JoinEvent`, `CML::Thread::Exit`, `CML::Thread::Prop`, `CML::Thread::Flag` live under `CML::Thread`
- Channels and events:
  - `CML.channel` → `Chan(T)`
  - `send`, `recv`, `send_evt`, `recv_evt`, `send_poll`, `recv_poll`, `same_channel`
  - Event combinators: `wrap(evt) { |x| ... }`, `guard { ... }`, `with_nack { |nack| ... }`, `choose(events)`, `always(value)`, `never`, `timeout(span)`, `nack` handling follows SML/NJ semantics
  - Synchronization: `CML.sync(evt)` (blocking), `CML.select(events)` convenience

## Synchronization Variables

- `CML::IVar(T)`:
  - `i_put`, `i_get`, `i_get_evt`, `i_get_poll`, `same?`
- `CML::MVar(T)`:
  - `m_put`, `m_take`, `m_get`, `m_get_evt`, `m_swap`, `m_update`, `m_take_then_put`, `m_is_empty?`, `m_get_poll`, `same?`
- `CML::CVar` (condition variable):
  - States: `CVar::Unset`, `CVar::Set(T)`
  - Operations: `cvar`, `cvar_set_evt`, `cvar_set`, `cvar_wait_evt`, `cvar_wait`
- `CML::Mailbox`:
  - `Mailbox::T(T)` implements asynchronous mailbox
  - `Mailbox.mailbox`, `Mailbox.recv`, `Mailbox.recv_evt`, `Mailbox.recv_poll`, `Mailbox.same?`, `Mailbox.send`
- `CML::Barrier`:
  - `Barrier.new(count)`, `Barrier.sync`, `Barrier.sync_evt`, `Barrier.trigger`, `Barrier.reset`

## Multicast

- Namespace: `CML::Multicast`
  - Channel type: `Multicast::Chan(T)` with `multicast(value)` and `port`
  - Port type: `Multicast::Port(T)` with `recv`, `recv_evt`, `copy`
  - Internals (`State`, `Message`, `NewPort`, `PortRecvEvent`) are namespaced and not exported via `CML`
  - CML helpers: `CML.mchannel(T)`, `CML.multicast(chan, value)`

## Linda (tuple spaces)

- Namespace: `CML::Linda`
  - `TupleSpace` with `out(tuple)`, `rd(pattern)`, `in(pattern)` plus corresponding `_evt` variants
  - Built atop `Mailbox`/channels; mirrors Chapter 9 examples from the book using `IVar`, `MVar`, and multicast patterns.

## IO Events

- Namespace: `CML::IOEvents`
  - `read_evt(io, n, nack: nil)` → `Event(Bytes)` (non-blocking registration, honors nack)
  - `read_line_evt(io, nack: nil)` → `Event(String?)`
  - `write_evt(io, bytes, nack: nil)` → `Event(Int32)` (bytes written)
  - `copy_evt(src, dst, chunk = 32_768, nack: nil)` → `Event(Nil)` copies until EOF
  - All events use `IO#wait_readable`/`wait_writable` when available. Stubs live in `src/ext/io_wait_readable*.cr` (non-evented and evented variants; require the evented one explicitly when using `IO::Evented`).

## Socket

- Namespace: `CML::Socket`
  - `accept_evt(server_socket)` → `Event(::Socket)` accepts a connection with nack-aware cancellation
  - `connect_evt(address, port, family = ::Socket::Family::INET, type = ::Socket::Type::STREAM)` → `Event(::Socket)`
  - `close_evt(socket)` → `Event(Nil)` closes when synchronized
- Namespace: `CML::Socket::UDP`
  - `recv_evt(udp_socket, size)` → `Event(Tuple(Bytes, ::Socket::IPAddress))`
  - `send_evt(udp_socket, payload, addr)` → `Event(Int32)`

## Processes

- Namespace: `CML::Process`
  - `system_evt(cmd : String)` → `Event(Process::Status)`
  - `system_command_evt(cmd, args: Array(String), input: String | Bytes | Nil = nil, env: ENV?, chdir: String? = nil)` → `Event(Process::Status)` (spawns once synchronized)

## RPC (simple request/response helpers)

- Namespace: `RPC`
  - `RPC::Endpoint`, `RPC::In`, `RPC::Out`, `RPC::InOut` wrap channels for structured calls
  - `RPC.make_rpc_server(handler)` returns `{rpc_endpoint, server_tid}`
  - CML helpers `CML.rpc_service` / `CML.stateful_rpc_service` delegate to `RPC`

## Threads utilities

- Namespace: `CML::Thread`
  - `Thread::Id`, `Thread::JoinEvent`, `Thread::Exit`, `Thread::Prop`, `Thread::Flag` (internal coordination for joins/exit propagation)
  - Use `CML.spawn`/`join_evt` instead of constructing directly.

## Mailbox/Barrier quick API table

- Mailbox: `mailbox`, `send`, `recv`, `recv_evt`, `recv_poll`, `same?`
- Barrier: `Barrier.new(n)`, `sync`, `sync_evt`, `trigger`, `reset`

## Naming differences from SML/NJ

- Many subsystems are namespaced: `CML::Multicast`, `CML::IOEvents`, `CML::Socket`, `CML::Process`, `CML::Thread`, `RPC`. Use the module-qualified names instead of the flatter SML/NJ structure.
- Thread identifiers are `CML::Thread::Id`; combinators still live under `CML`.
- IO wait helpers are optional: require `src/ext/io_wait_readable_evented.cr` when running on an evented runtime; the default stub is non-evented.

## Conventions and semantics

- **One-commit rule**: Each `choose` completes exactly one branch. Registration is non-blocking; only `sync` suspends.
- **Cancellation**: `with_nack` and nack-aware IO/process/socket events honor cancellation requests to avoid spurious work.
- **Determinism**: Avoid arbitrary sleeps; prefer timeouts as events. Fiber scheduling is cooperative.
- **No hidden blocking**: Event registration must not block. Only synchronizing (`sync`) should park a fiber.

## Examples

- See `examples/` for runnable demonstrations:
  - Channels and barriers: `barrier_*`, `simple_barrier_join_example`, `event_awaits_sync`
  - Pipelines and chat: `pipeline_demo`, `chat_demo`
  - Timeouts: `timeout_worker_demo`
  - Build system (Chapter 7 style): `examples/build_system`
  - Linda (Chapter 9.1 style): `examples/linda`

## Mapping to SML/NJ docs

- Content corresponds to `cml.mldoc`, `sync-var.mldoc`, `mailbox.mldoc`, `barrier.mldoc`, `os.mldoc`, `os-process.mldoc`, `os-io.mldoc`, `run-cml.mldoc`, and `refman.mldoc`.
- Use this manual as the Crystal-specific reference; semantics follow the original CML descriptions unless noted in the naming differences section.
