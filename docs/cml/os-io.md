# The OS.IO structure

This document is adapted from the SML/NJ CML documentation (`os-io.mldoc`) for
the Crystal CML implementation. The OS.IO structure provides event-based polling
of I/O devices, modeled after the Unix poll interface.

## Overview

In SML/NJ CML, `OS.IO` provides a `pollEvt` function that takes a list of poll
descriptors and returns an event that becomes enabled when any of the
descriptors are ready for I/O. This allows monitoring multiple file descriptors
simultaneously.

Crystal CML provides similar functionality through the `CML::IOEvents` module
and `CML::PrimitiveIO` backend, though the API differs significantly.

## Namespace

| SML/NJ Structure | Crystal Location | Description |
|-----------------|------------------|-------------|
| `OS.IO` | `CML::IOEvents` module | I/O event operations |
| `OS.IO.pollEvt` | `CML::PrimitiveIO.wait_*_evt` functions | Low-level polling events |

## Types

### Poll Descriptors

SML/NJ uses `poll_desc` values to specify I/O conditions to monitor (readable,
writable, exceptional). Crystal uses `IO::FileDescriptor` objects directly with
specific event functions.

```crystal
# SML: poll_desc
# Crystal: IO::FileDescriptor + event type
fd = STDIN.fd
```

### Poll Information

SML/NJ returns `poll_info` values indicating which descriptors are ready.
Crystal's events return the ready descriptor or data directly.

```crystal
# SML: poll_info list
# Crystal: Event returns the data (String, Bytes, etc.) or descriptor ready
```

## Functions

### `pollEvt`

**SML signature**: `val pollEvt : poll_desc list -> poll_info list event`

**Crystal equivalents**:

Crystal provides separate events for different I/O operations rather than a
generic poll function:

```crystal
# Wait for a file descriptor to become readable
CML::PrimitiveIO.wait_readable_evt(fd : IO::FileDescriptor, nack : Event(Nil)? = nil) : Event(Nil)

# Wait for a file descriptor to become writable
CML::PrimitiveIO.wait_writable_evt(fd : IO::FileDescriptor, nack : Event(Nil)? = nil) : Event(Nil)

# Read up to n bytes from a descriptor
CML.read_evt(io : IO, bytes : Int32) : Event(Bytes)

# Write bytes to a descriptor
CML.write_evt(io : IO, data : Bytes) : Event(Int32)
```

**Description**:

Monitors a list of poll descriptors for I/O readiness. The event becomes enabled
when any descriptor is ready for the requested operation(s). Raises `OS.SysErr`
if a file descriptor is invalid.

**Crystal usage**:

To monitor multiple descriptors, use `CML.choose` with individual wait events:

```crystal
fd1 = socket1.fd
fd2 = socket2.fd

choice = CML.choose(
  CML::PrimitiveIO.wait_readable_evt(fd1).wrap { :socket1 },
  CML::PrimitiveIO.wait_readable_evt(fd2).wrap { :socket2 }
)

ready = CML.sync(choice)  # :socket1 or :socket2
```

## Error Handling

SML/NJ raises `OS.SysErr` for invalid file descriptors or system errors. Crystal
raises `IO::Error` or `Errno` exceptions for I/O errors.

```crystal
begin
  CML.sync(CML.read_evt(io, 1024))
rescue ex : IO::Error
  # Handle I/O error
end
```

## Porting Notes

When porting SML/NJ code that uses `OS.IO.pollEvt`:

1.  **Single descriptor polling**: Replace with
   `CML::PrimitiveIO.wait_readable_evt` or `wait_writable_evt`
2.  **Multiple descriptor polling**: Use `CML.choose` with individual wait events
3.  **Read/write operations**: Use `CML.read_evt` or `CML.write_evt` directly
4.  **Poll descriptors**: Crystal uses `IO::FileDescriptor` objects (obtained via
   `io.fd`)

**Example conversion**:

**SML/NJ**:

```sml
val descs = [POLL_IN fd1, POLL_OUT fd2]
val pollEvt = OS.IO.pollEvt descs
val ready = CML.sync pollEvt
```

**Crystal**:

```crystal
choice = CML.choose(
  CML::PrimitiveIO.wait_readable_evt(fd1).wrap { :readable },
  CML::PrimitiveIO.wait_writable_evt(fd2).wrap { :writable }
)
ready = CML.sync(choice)
```

## See Also

*   [OS Documentation](os.md) - OS structure overview
*   [CML Documentation](cml.md) - Core CML functions
*   [Crystal CML Manual](../cml_manual.md) - High-level overview
*   [SML/NJ OS.IO Documentation](https://www.smlnj.org/doc/) - Original
  documentation

---

*Adapted from SML/NJ OS.IO documentation version 1.5 (2003-03-10)*
