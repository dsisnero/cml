# The Barrier structure

This document is adapted from the SML/NJ CML documentation (`barrier.mldoc`) for
the Crystal CML implementation.

## Overview

The `Barrier` structure provides support for barrier synchronization with global
state. Note that unlike most other synchronization mechanisms in CML, barriers
do not have event-value operations in the SML/NJ API (though Crystal provides
them as extensions).

In Crystal, barriers are implemented as `CML::Barrier(T)` class with
`CML::Barrier::Enrollment(T)` inner class. Crystal provides both the SML/NJ
functional barrier and a simpler counting barrier.

## Types

### `Barrier(T)`

**SML**: `type 'a barrier`

**Crystal**: `class CML::Barrier(T)`

**Description**: This is the type constructor for a barrier. A barrier allows
multiple threads to synchronize at a common point. When all enrolled threads
reach the barrier, they are all released and the global state is updated.

### `Enrollment(T)`

**SML**: `type 'a enrollment`

**Crystal**: `class CML::Barrier::Enrollment(T)`

**Description**: This type constructor represents an *enrollment* on a barrier.
Enrollments are used to synchronize on barriers. The (unenforced) convention is
that each enrolled thread belongs to a thread and that a thread owns at most one
enrollment on a given barrier.

## Functions

### `barrier`

**SML signature**: `val barrier : ('a -> 'a) -> 'a -> 'a barrier`

**Crystal equivalent**:

```crystal
def self.barrier(update_fn : Proc(T, T), initial_state : T) : Barrier(T)
# Block-based constructor:
def self.barrier(initial_state : T, &block : T -> T) : Barrier(T)
```

**Description**: Creates a new barrier with the update function `update` and the
initial state `init`. The state is updated each time the barrier is synchronized
on by the enrolled threads.

**Prototype**:

```crystal
# Using proc
barrier = CML.barrier(->(x : Int32) { x + 1 }, 0)
# Using block
barrier = CML.barrier(0) { |x| x + 1 }
```

### `enroll`

**SML signature**: `val enroll : 'a barrier -> 'a enrollment`

**Crystal equivalent**:

```crystal
# Instance method on Barrier(T)
def enroll : Enrollment(T)
```

**Description**: Enrolls on the barrier, returning a new `enrollment`. The
convention is that each enrolled thread belongs to a thread and that a thread
owns at most one enrollment on a given barrier.

**Prototype**:

```crystal
enrollment = barrier.enroll
```

### `wait`

**SML signature**: `val wait : 'a enrollment -> 'a`

**Crystal equivalent**:

```crystal
# Instance method on Enrollment(T)
def wait : T
```

**Description**: Waits on the barrier until all of the enrolled threads are
waiting, at which point the state is updated and the resulting state value is
returned to the waiting threads. If another thread is already waiting on this
enrollment or if the enrollment has been resigned, then an exception is raised.

Note that if the update function for the barrier raises an exception, then this
exception is raised for each waiting thread by `wait`.

**Prototype**:

```crystal
state = enrollment.wait
```

### `resign`

**SML signature**: `val resign : 'a enrollment -> unit`

**Crystal equivalent**:

```crystal
# Instance method on Enrollment(T)
def resign : Nil
```

**Description**: Resigns from the enrollment `ebar`. Resigning from an already
resigned enrollment is ignored, but if another thread is waiting on this
enrollment, then an exception is raised.

**Prototype**:

```crystal
enrollment.resign
```

### `value`

**SML signature**: `val value : 'a enrollment -> 'a`

**Crystal equivalent**:

```crystal
# Instance method on Enrollment(T)
def value : T
```

**Description**: Gets the current value of the barrier's state. Note that if the
convention of one-thread per enrollment is followed, then this operation is free
of races, since the state is stable between barrier synchronizations.

**Prototype**:

```crystal
current_state = enrollment.value
```

## Additional Crystal Methods

### `wait_evt`

```crystal
def wait_evt : Event(T)
```

Returns an event value for waiting on the barrier, allowing barrier
synchronization to be used in `choose` expressions. This is a Crystal extension
not present in SML/NJ.

### Status Check Methods

```crystal
def enrolled? : Bool
def waiting? : Bool
def resigned? : Bool
```

Query the status of an enrollment.

### Counting Barrier

Crystal also provides a simpler counting barrier:

```crystal
def self.counting_barrier(count : Int32) : Barrier(Nil)
```

Creates a barrier that releases when `count` threads have synchronized. The
state is always `nil`.

**Example**:

```crystal
barrier = CML.counting_barrier(3)
# Spawn 3 threads that wait on barrier
```

## Example

Barriers can be used to implement clock and phased synchronization. For example:

```crystal
# SML/NJ style example adapted to Crystal
clock = CML.barrier(0) { |x| x + 1 }

def spawn_child(clock)
  enrollment = clock.enroll
  spawn do
    loop do
      break if enrollment.wait == 5
    end
  end
end

# Parent enrolls first to avoid race condition
parent_enrollment = clock.enroll
spawn_child(clock)
spawn_child(clock)
parent_enrollment.resign
```

In this example, two threads are spawned, which then synchronize on the barrier
five times. To avoid a race condition between enrollment and the first
synchronization, the parent thread enrolls on the barrier prior to spawning its
children and then resigns after the children have been enrolled.

## See Also

*   [SML/NJ Barrier documentation](https://www.smlnj.org/doc/) (original)
*   [CML documentation](cml.md) (core CML structure)
*   [SyncVar documentation](sync-var.md) (synchronization variables)
*   [Mailbox documentation](mailbox.md) (asynchronous channels)
*   [Crystal CML Manual](../cml_manual.md) (Crystal-specific overview)

---

*Adapted from SML/NJ Barrier documentation version 1.0 (2011-02-18)*
