# The SyncVar structure

This document is adapted from the SML/NJ CML documentation (`sync-var.mldoc`)
for the Crystal CML implementation.

## Overview

The `SyncVar` structure provides Id-style synchronous variables (or memory
cells). These variables have two states: *empty* and *full*. An attempt to read
a value from an empty variable blocks the calling thread until there is a value
available. An attempt to put a value into a variable that is full results in the
`PutError` exception being raised.

There are two kinds of synchronous variables: I-variables are write-once, while
M-variables are mutable.

In Crystal, these are implemented as `CML::IVar(T)` and `CML::MVar(T)` classes.
Module functions are available via `CML.ivar`, `CML.mvar`, etc.

## Exception

### `PutError`

**SML**: `exception Put`

**Crystal**: `class PutError < Exception`

**Description**: This exception is raised when an attempt is made to put a value
into a variable that is already full (see `i_put` and `m_put`).

## I-Variables (Write-Once)

### Type `IVar(T)`

**SML**: `type 'a ivar`

**Crystal**: `class CML::IVar(T)`

**Description**: This is the type constructor for I-structured variables.
I-structured variables are write-once variables that provide synchronization on
read operations. They are especially useful for one-shot communications, such as
reply messages in client/server protocols, and can also be used to implement
shared *incremental* data structures.

### `ivar`

**SML signature**: `val iVar : unit -> 'a ivar`

**Crystal equivalent**:

```crystal
def self.ivar(type : T.class) : IVar(T) forall T
```

**Description**:
Creates a new empty I-variable.

**Prototype**:

```crystal
ivar(Int32)  # returns IVar(Int32)
```

### `i_put`

**SML signature**: `val iPut : ('a ivar * 'a) -> unit`

**Crystal equivalent**:

```crystal
# Instance method on IVar(T)
def i_put(value : T) : Nil
```

**Description**: Fills the I-variable `iv` with the value `value`. Any threads
that are blocked on `iv` will be resumed. If `iv` already has a value in it,
then the `PutError` exception is raised.

**Prototype**:

```crystal
iv.i_put(x)
```

### `i_get`

**SML signature**: `val iGet : 'a ivar -> 'a`

**Crystal equivalent**:

```crystal
# Instance method on IVar(T)
def i_get : T
```

**Description**: Returns the contents of the I-variable `iv`. If the variable is
empty, then the calling thread blocks until the variable becomes full.

**Prototype**:

```crystal
iv.i_get
```

### `i_get_evt`

**SML signature**: `val iGetEvt : 'a ivar -> 'a event`

**Crystal equivalent**:

```crystal
# Instance method on IVar(T)
def i_get_evt : Event(T)
```

**Description**:
Returns an event-value that represents the `i_get` operation on `iv`.

**Prototype**:

```crystal
iv.i_get_evt
```

### `i_get_poll`

**SML signature**: `val iGetPoll : 'a ivar -> 'a option`

**Crystal equivalent**:

```crystal
# Instance method on IVar(T)
def i_get_poll : T?
```

**Description**: This is a non-blocking version of `i_get`. If the corresponding
blocking form would block, then it returns `nil`; otherwise it returns the
variable's contents.

**Prototype**:

```crystal
iv.i_get_poll
```

### `same_ivar`

**SML signature**: `val sameIVar : ('a ivar * 'a ivar) -> bool`

**Crystal equivalent**:

```crystal
def self.same_ivar(v1 : IVar(T), v2 : IVar(T)) : Bool forall T
# Also instance method:
def same?(other : IVar(T)) : Bool
```

**Description**:
Returns `true` if `iv1` and `iv2` are the same I-variable.

**Prototype**:

```crystal
same_ivar(iv1, iv2)
iv1.same?(iv2)
```

## M-Variables (Mutable)

### Type `MVar(T)`

**SML**: `type 'a mvar`

**Crystal**: `class CML::MVar(T)`

**Description**: This is the type constructor for M-structured variables. Unlike
`IVar` values, M-structured variables may be updated multiple times. Like
I-variables, however, they may only be written if they are empty.

### `mvar`

**SML signature**: `val mVar : unit -> 'a mvar`

**Crystal equivalent**:

```crystal
def self.mvar(type : T.class) : MVar(T) forall T
```

**Description**:
Creates a new empty M-variable.

**Prototype**:

```crystal
mvar(Int32)  # returns MVar(Int32)
```

### `mvar_init`

**SML signature**: `val mVarInit : 'a -> 'a mvar`

**Crystal equivalent**:

```crystal
def self.mvar_init(value : T) : MVar(T) forall T
```

**Description**:
Creates a new M-variable initialized to `value`.

**Prototype**:

```crystal
mvar_init(42)  # returns MVar(Int32) with value 42
```

### `m_put`

**SML signature**: `val mPut : ('a mvar * 'a) -> unit`

**Crystal equivalent**:

```crystal
# Instance method on MVar(T)
def m_put(value : T) : Nil
```

**Description**: Fills the M-variable `mv` with the value `value`. Any threads
that are blocked on `mv` will be resumed. If `mv` already has a value in it,
then the `PutError` exception is raised.

**Prototype**:

```crystal
mv.m_put(x)
```

### `m_take`

**SML signature**: `val mTake : 'a mvar -> 'a`

**Crystal equivalent**:

```crystal
# Instance method on MVar(T)
def m_take : T
```

**Description**: Removes and returns the contents of the M-variable `mv` making
it empty. If the variable is already empty, then the calling thread is blocked
until a value is available.

**Prototype**:

```crystal
mv.m_take
```

### `m_take_evt`

**SML signature**: `val mTakeEvt : 'a mvar -> 'a event`

**Crystal equivalent**:

```crystal
# Instance method on MVar(T)
def m_take_evt : Event(T)
```

**Description**:
Returns an event-value that represents the `m_take` operation on `mv`.

**Prototype**:

```crystal
mv.m_take_evt
```

### `m_get`

**SML signature**: `val mGet : 'a mvar -> 'a`

**Crystal equivalent**:

```crystal
# Instance method on MVar(T)
def m_get : T
```

**Description**: Returns the contents of the M-variable `mv` without emptying
the variable; if the variable is empty, then the thread blocks until a value is
available. It is equivalent to:

```crystal
x = mv.m_take
mv.m_put(x)
x
```

**Prototype**:

```crystal
mv.m_get
```

### `m_get_evt`

**SML signature**: `val mGetEvt : 'a mvar -> 'a event`

**Crystal equivalent**:

```crystal
# Instance method on MVar(T)
def m_get_evt : Event(T)
```

**Description**:
Returns an event-value that represents the `m_get` operation on `mv`.

**Prototype**:

```crystal
mv.m_get_evt
```

### `m_take_poll` and `m_get_poll`

**SML signature**:

*   `val mTakePoll : 'a mvar -> 'a option`
*   `val mGetPoll : 'a mvar -> 'a option`

**Crystal equivalent**:

```crystal
# Instance methods on MVar(T)
def m_take_poll : T?
def m_get_poll : T?
```

**Description**: These are non-blocking versions of `m_take` and `m_get`
(respectively). If the corresponding blocking form would block, then they return
`nil`; otherwise they return the variable's contents.

**Prototype**:

```crystal
mv.m_take_poll
mv.m_get_poll
```

### `m_swap`

**SML signature**: `val mSwap : ('a mvar * 'a) -> 'a`

**Crystal equivalent**:

```crystal
# Instance method on MVar(T)
def m_swap(new_value : T) : T
```

**Description**: Puts the value `new_value` into the M-variable `mv` and returns
the previous contents. If the variable is empty, then the thread blocks until a
value is available. It is equivalent to:

```crystal
x = mv.m_take
mv.m_put(new_value)
x
```

except that `m_swap` is executed atomically.

**Prototype**:

```crystal
mv.m_swap(new_value)
```

### `m_swap_evt`

**SML signature**: `val mSwapEvt : ('a mvar * 'a) -> 'a event`

**Crystal equivalent**:

```crystal
# Instance method on MVar(T)
def m_swap_evt(new_value : T) : Event(T)
```

**Description**: Returns an event-value that represents the `m_swap` operation
on `mv` and `new_value`.

**Prototype**:

```crystal
mv.m_swap_evt(new_value)
```

### `same_mvar`

**SML signature**: `val sameMVar : ('a mvar * 'a mvar) -> bool`

**Crystal equivalent**:

```crystal
def self.same_mvar(v1 : MVar(T), v2 : MVar(T)) : Bool forall T
# Also instance method:
def same?(other : MVar(T)) : Bool
```

**Description**:
Returns `true` if `mv1` and `mv2` are the same M-variable.

**Prototype**:

```crystal
same_mvar(mv1, mv2)
mv1.same?(mv2)
```

## Usage Notes

I-variables provide a useful mechanism for implementing the reply communication
in request/reply protocols (in cases where the server does not care if the reply
is accepted). They may also be used to implement incremental data structures and
streams; for example, the `Multicast` structure uses I-variables to implement
its multicast channels.

A disciplined use of M-variables can provide an atomic read-modify-write
operation.

## See Also

*   [SML/NJ SyncVar documentation](https://www.smlnj.org/doc/) (original)
*   [CML documentation](cml.md) (core CML structure)
*   [Crystal CML Manual](../cml_manual.md) (Crystal-specific overview)

---

*Adapted from SML/NJ SyncVar documentation version 1.1 (2003-03-10)*
