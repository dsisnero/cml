# The CML structure

This document is adapted from the SML/NJ CML documentation (`cml.mldoc`) for the Crystal CML implementation. Where the Crystal API differs from SML/NJ, notes are provided.

## Overview

CML (Concurrent ML) provides first-class synchronous operations represented as event values (`Event(T)`). Only `CML.sync(evt)` blocks a fiber; event registration must remain non-blocking. The Crystal implementation follows SML/NJ semantics with adaptations for Crystal's type system and fiber-based concurrency.

## Namespace

In Crystal, all CML functions are in the `CML` module. Thread-related types are in `CML::Thread`.

## Types

```crystal
# Thread ID type (SML: thread_id)
CML::Thread::Id

# Channel type constructor (SML: 'a chan)
CML::Chan(T)

# Event type constructor (SML: 'a event)
CML::Event(T)
```

## Version Information

```crystal
# SML: version : {system : string, version_id : int list, date : string}
CML.version : NamedTuple(system: String, version_id: Array(Int32), date: String)

# SML: banner : string
CML.banner : String
```

These specify the version of CML in a format similar to SML/NJ.

## Thread Operations

### `spawnc`

**SML signature**: `val spawnc : ('a -> unit) -> 'a -> thread_id`

**Crystal equivalent**:

```crystal
def self.spawnc(arg : A, &block : A -> Nil) : Thread::Id forall A
```

**Description**:
Creates a new thread of control to evaluate the body of the block with argument `arg`. A new unique ID for the thread is created and returned.

**Prototype**:

```crystal
spawnc(arg) { |a| ... }
```

### `spawn`

**SML signature**: `val spawn : (unit -> unit) -> thread_id`

**Crystal equivalent**:

```crystal
def self.spawn(&block : -> Nil) : Thread::Id
```

**Description**:
Creates a new thread of control to evaluate the body of the block.

**Prototype**:

```crystal
spawn { ... }
```

### `yield`

**SML signature**: `val yield : unit -> unit`

**Crystal equivalent**:

```crystal
def self.yield : Nil
```

**Description**:
This function can be used to implement an explicit context switch. Since Crystal CML uses cooperative fiber scheduling (not preemptive), this function may be more useful than in SML/NJ for explicit yielding. It is also used for performance measurements.

### `exit`

**SML signature**: `val exit : unit -> 'a`

**Crystal equivalent**:

```crystal
def self.exit : NoReturn
```

**Description**:
Causes the calling thread to terminate by raising `CML::Thread::Exit` exception.

**Prototype**:

```crystal
exit()
```

### `get_tid`

**SML signature**: `val getTid : unit -> thread_id`

**Crystal equivalent**:

```crystal
def self.get_tid : Thread::Id
```

**Description**:
Returns the thread ID of the calling thread.

**Prototype**:

```crystal
get_tid()
```

### `same_tid`

**SML signature**: `val sameTid : (thread_id * thread_id) -> bool`

**Crystal equivalent**:

```crystal
def self.same_tid(tid1 : Thread::Id, tid2 : Thread::Id) : Bool
```

**Description**:
Returns `true` if the two thread IDs are the same ID.

**Prototype**:

```crystal
same_tid(tid1, tid2)
```

### `compare_tid`

**SML signature**: `val compareTid : (thread_id * thread_id) -> order`

**Crystal equivalent**:

```crystal
def self.compare_tid(tid1 : Thread::Id, tid2 : Thread::Id) : Int32
```

**Description**:
Compares the two thread IDs and returns their order in the total ordering of thread IDs. Returns -1 if `tid1 < tid2`, 0 if equal, 1 if `tid1 > tid2`. The precise semantics of this ordering is left unspecified, other than to say it is a total order.

**Prototype**:

```crystal
compare_tid(tid1, tid2)
```

### `hash_tid`

**SML signature**: `val hashTid : thread_id -> word`

**Crystal equivalent**:

```crystal
def self.hash_tid(tid : Thread::Id) : UInt64
```

**Description**:
Returns a hash of the thread ID `tid`.

**Prototype**:

```crystal
hash_tid(tid)
```

### `tid_to_string`

**SML signature**: `val tidToString : thread_id -> string`

**Crystal equivalent**:

```crystal
def self.tid_to_string(tid : Thread::Id) : String
```

**Description**:
Returns a string representation of the thread ID `tid`.

**Prototype**:

```crystal
tid_to_string(tid)
```

### `join_evt`

**SML signature**: `val joinEvt : thread_id -> unit event`

**Crystal equivalent**:

```crystal
def self.join_evt(tid : Thread::Id) : Event(Nil)
```

**Description**:
Creates an event value for synchronizing on the termination of the thread with the ID `tid`. There are three ways that a thread may terminate: the block passed to `spawn` (or `spawnc`) may return; it may call the `exit` function, or it may have an uncaught exception. Note that `join_evt` does not distinguish between these cases; it also does not become enabled if the named thread deadlocks (even if it is garbage collected).

**Prototype**:

```crystal
join_evt(tid)
```

## Channel Operations

### `channel`

**SML signature**: `val channel : unit -> 'a chan`

**Crystal equivalent**:

```crystal
def self.channel(type : T.class) : Chan(T) forall T
```

**Description**:
Creates a new synchronous channel. Note: Crystal requires explicit type parameter.

**Prototype**:

```crystal
channel(Int32)  # returns Chan(Int32)
```

### `same_channel`

**SML signature**: `val sameChannel : ('a chan * 'a chan) -> bool`

**Crystal equivalent**:

```crystal
def self.same_channel(ch1 : Chan(T), ch2 : Chan(T)) : Bool forall T
```

**Description**:
Returns `true` if the two channels are the same channel.

**Prototype**:

```crystal
same_channel(ch1, ch2)
```

### `send`

**SML signature**: `val send : ('a chan * 'a) -> unit`

**Crystal equivalent**:

```crystal
# As instance method on Chan(T)
def send(value : T) : Nil

# Or via CML.sync with send_evt
CML.sync(ch.send_evt(value))
```

**Description**:
Sends the message `value` on the synchronous channel `ch`. This operation blocks the calling thread until there is another thread attempting to receive a message from the channel `ch`, at which point the receiving thread gets the message and both threads continue execution.

**Prototype**:

```crystal
ch.send(msg)
```

### `recv`

**SML signature**: `val recv : 'a chan -> 'a`

**Crystal equivalent**:

```crystal
# As instance method on Chan(T)
def recv : T

# Or via CML.sync with recv_evt
CML.sync(ch.recv_evt)
```

**Description**:
Receives a message from the channel `ch`. This operation blocks the calling thread until there is another thread attempting to send a message on the channel `ch`, at which point both threads continue execution.

**Prototype**:

```crystal
ch.recv
```

### `send_evt`

**SML signature**: `val sendEvt : ('a chan * 'a) -> unit event`

**Crystal equivalent**:

```crystal
# As instance method on Chan(T)
def send_evt(value : T) : Event(Nil)
```

**Description**:
Creates an event value to represent the `send` operation.

**Prototype**:

```crystal
ch.send_evt(msg)
```

### `recv_evt`

**SML signature**: `val recvEvt : 'a chan -> 'a event`

**Crystal equivalent**:

```crystal
# As instance method on Chan(T)
def recv_evt : Event(T)
```

**Description**:
Creates an event value to represent the `recv` operation.

**Prototype**:

```crystal
ch.recv_evt
```

### `send_poll`

**SML signature**: `val sendPoll : ('a chan * 'a) -> bool`

**Crystal equivalent**:

```crystal
# As instance method on Chan(T)
def send_poll(value : T) : Bool
```

**Description**:
Attempts to send the message `value` on the synchronous channel `ch`. If this operation can complete without blocking the calling thread, then the message is sent and `true` is returned. Otherwise, no communication is performed and `false` is returned. This function is not recommended for general use; it is provided as an efficiency aid for certain kinds of protocols.

**Prototype**:

```crystal
ch.send_poll(msg)
```

### `recv_poll`

**SML signature**: `val recvPoll : 'a chan -> 'a option`

**Crystal equivalent**:

```crystal
# As instance method on Chan(T)
def recv_poll : T?
```

**Description**:
Attempts to receive a message from the channel `ch`. If there is no other thread offering to `send` a message on `ch`, then this returns `nil`, otherwise it returns the message. This function is not recommended for general use; it is provided as an efficiency aid for certain kinds of protocols.

**Prototype**:

```crystal
ch.recv_poll
```

## Event Combinators

### `wrap`

**SML signature**: `val wrap : ('a event * ('a -> 'b)) -> 'b event`

**Crystal equivalent**:

```crystal
def self.wrap(evt : Event(A), &f : A -> B) : Event(B) forall A, B
```

**Description**:
Wraps the post-synchronization action `f` around the event value `evt`.

**Prototype**:

```crystal
wrap(evt) { |x| ... }
```

### `wrap_handler`

**SML signature**: `val wrapHandler : ('a event * (exn -> 'a event)) -> 'a event`

**Crystal equivalent**:

```crystal
def self.wrap_handler(evt : Event(T), &handler : Exception -> T) : Event(T) forall T
```

**Description**:
Wraps the exception handler function `handler` around the event value `evt`. If, during execution of some post-synchronization action in `evt`, an exception is raised, it will be caught and passed to `handler`. Nesting of handlers works as would be expected: the innermost handler is the first one invoked. Note that exceptions raised in the pre-synchronization actions in `evt` (i.e., actions defined by `guard` and `with_nack`) are not handled by `handler`.

**Prototype**:

```crystal
wrap_handler(evt) { |exn| ... }
```

### `guard`

**SML signature**: `val guard : (unit -> 'a event) -> 'a event`

**Crystal equivalent**:

```crystal
def self.guard(&block : -> Event(T)) : Event(T) forall T
```

**Description**:
Creates a *delayed* event value from the block `block`. When the resulting event value is synchronized on, the block will be evaluated and the resulting event value will be used in its place in the synchronization. This provides a mechanism for implementing pre-synchronization actions, such as sending a request to a server.

**Prototype**:

```crystal
guard { ... }
```

### `with_nack`

**SML signature**: `val withNack : (unit event -> 'a event) -> 'a event`

**Crystal equivalent**:

```crystal
def self.with_nack(&f : Event(Nil) -> Event(T)) : Event(T) forall T
```

**Description**:
Creates a *delayed* event value from the function `f`. As in the case of `guard`, the function `f` will be evaluated at synchronization time and the resulting event value will be used in its place in the synchronization. Furthermore, when `f` is evaluated, it is passed a *negative acknowledgement* event as an argument. This negative acknowledgement event is enabled in the case where some other event involved in the synchronization is chosen instead of the one produced by `f`. The `with_nack` combinator provides a mechanism for informing servers that a client has aborted a transaction.

**Prototype**:

```crystal
with_nack { |nack_evt| ... }
```

### `choose`

**SML signature**: `val choose : 'a event list -> 'a event`

**Crystal equivalent**:

```crystal
def self.choose(events : Array(Event(T))) : Event(T) forall T
def self.choose(*events : Event(T)) : Event(T) forall T
```

**Description**:
Constructs an event value that represents the non-deterministic choice of the events in the list `events`.

**Prototype**:

```crystal
choose([evt1, evt2, evt3])
choose(evt1, evt2, evt3)  # varargs version
```

### `sync`

**SML signature**: `val sync : 'a event -> 'a`

**Crystal equivalent**:

```crystal
def self.sync(evt : Event(T)) : T forall T
```

**Description**:
Synchronizes the calling thread on the event `evt`.

**Prototype**:

```crystal
sync(evt)
```

### `select`

**SML signature**: `val select : 'a event list -> 'a`

**Crystal equivalent**:

```crystal
def self.select(events : Array(Event(T))) : T forall T
```

**Description**:
Synchronizes on the non-deterministic choice of the events in the list `events`. It is semantically equivalent to `sync(choose(events))` but is more efficient.

**Prototype**:

```crystal
select([evt1, evt2, evt3])
```

### `never`

**SML signature**: `val never : 'a event`

**Crystal equivalent**:

```crystal
def self.never(type : T.class) : Event(T) forall T
def self.never : Event(Nil)
```

**Description**:
An event value that is never enabled for synchronization. It is semantically equivalent to `choose([])`.

**Prototype**:

```crystal
never(Int32)  # Event(Int32) that never enables
never         # Event(Nil) that never enables (convenience)
```

### `always`

**SML signature**: `val alwaysEvt : 'a -> 'a event`

**Crystal equivalent**:

```crystal
def self.always(x : T) : Event(T) forall T
```

**Description**:
Creates an event value that is always enabled, and that returns the value `x` upon synchronization.

**Prototype**:

```crystal
always(value)
```

### `timeout`

**SML signature**: `val timeOutEvt : Time.time -> unit event`

**Crystal equivalent**:

```crystal
def self.timeout(duration : Time::Span) : Event(Nil)
```

**Description**:
Creates an event value that becomes enabled at the time interval `duration` after synchronization. For example, the expression `sync(timeout(1.second))` will delay the calling thread for one second. Note that the specified time interval is actually a minimum waiting time, and the delay may be longer.

**Prototype**:

```crystal
timeout(5.seconds)
```

### `at_time`

**SML signature**: `val atTimeEvt : Time.time -> unit event`

**Crystal equivalent**:

```crystal
def self.at_time(target_time : Time) : Event(Nil)
```

**Description**:
Creates an event value that becomes enabled at the specified time `target_time`. For example, the expression blocks the calling thread until the specified absolute time.

**Prototype**:

```crystal
at_time(Time.utc(2026, 1, 1, 0, 0, 0))
```

## Additional Crystal Functions

The Crystal CML implementation includes several convenience functions not present in SML/NJ:

### `after`

```crystal
def self.after(duration : Time::Span, &block : -> T) : Event(T) forall T
```

Creates a timeout event that, when synchronized, executes the block and returns its result.

### `sleep`

```crystal
def self.sleep(duration : Time::Span)
```

Convenience function that synchronizes on a timeout event.

### `spawn_evt`

```crystal
def self.spawn_evt(&block : -> Nil) : Event(Thread::Id)
```

Creates an event that, when synchronized, spawns a new thread executing the block.

### `nack`

```crystal
def self.nack(evt : Event(T), &block : -> Nil) : Event(T) forall T
```

Adds a negative acknowledgement handler to an existing event.

## See Also

*   [SML/NJ CML documentation](https://www.smlnj.org/doc/) (original)
*   [Crystal CML Manual](../cml_manual.md) (Crystal-specific overview)
*   [SyncVar documentation](sync-var.md) (SML/NJ SyncVar structure adaptation)
*   [Thread documentation](thread.md) (Thread utilities)

---

*Adapted from SML/NJ CML documentation version 1.1 (2003-03-10)*
