# The TraceCML structure

This document is adapted from the SML/NJ CML documentation (`trace-cml.mldoc`) for the Crystal CML implementation. The TraceCML structure provides debugging support through trace output control, thread termination monitoring, and uncaught exception handling.

## Overview

SML/NJ's `TraceCML` provides three main facilities:

1.  **Trace modules** - Hierarchical namespace for controlling debugging output granularity
2.  **Thread watching** - Detection of thread termination (useful for monitoring servers)
3.  **Uncaught exception handling** - Custom actions when threads terminate due to uncaught exceptions

Crystal CML provides a different tracing system based on conditional compilation (`-Dtrace`) and macro-based output. The API is simpler but covers similar use cases.

## Namespace

| SML/NJ Structure | Crystal Location | Description |
|-----------------|------------------|-------------|
| `TraceCML` | `CML::Tracer` class + `CML.trace` macro | Tracing and debugging support |
| Trace modules | Tags and event type filters | Hierarchical control via filtering |
| Thread watching | Manual monitoring via `CML::Thread.join_evt` | No automatic watching |
| Uncaught exception handling | Crystal's `Fiber#rescue` or custom handlers | Different mechanism |

## Types

### `trace_module`

**SML type**: `trace_module` - Element in hierarchical namespace controlling debugging output.

**Crystal equivalent**: Not a direct type. Use **tags** and **event types** for filtering:

```crystal
# Trace with tag (can be hierarchical using dot notation)
CML.trace "Chan.send", value, tag: "chan.send"

# Filter by tag
CML::Tracer.set_filter_tags(["chan.send"])
```

### `trace_to`

**SML datatype**:

```text
datatype trace_to =
    TraceToOut
  | TraceToErr
  | TraceToNull
  | TraceToFile of string
  | TraceToStream of TextIO.outstream
```

**Crystal equivalent**: `CML::Tracer.set_output(io : IO)`:

```crystal
# Output to STDOUT (default)
CML::Tracer.set_output(STDOUT)

# Output to STDERR
CML::Tracer.set_output(STDERR)

# Output to file
CML::Tracer.set_output(File.open("trace.log", "w"))

# Output to null (disable)
CML::Tracer.set_output(IO::Memory.new)
```

## Functions

### `setTraceFile`

**SML signature**: `val setTraceFile : trace_to -> unit`

**Crystal equivalent**: `CML::Tracer.set_output(io : IO)`

Sets the destination for trace output.

### `traceRoot`

**SML signature**: `val traceRoot : trace_module`

**Crystal equivalent**: No direct equivalent. The root of all tracing is always enabled when `-Dtrace` is set.

### `traceModule`

**SML signature**: `val traceModule : (trace_module * string) -> trace_module`

Creates a child trace module with given label.

**Crystal approach**: Use dot-separated tags:

```crystal
# Create hierarchical tags
CML.trace "Event.registration", pick, tag: "cml.event.registration"
CML.trace "Chan.send", value, tag: "cml.chan.send"

# Filter by prefix
CML::Tracer.set_filter_tags(["cml.chan"])
```

### `nameOf`

**SML signature**: `val nameOf : trace_module -> string`

**Crystal equivalent**: Tags are strings, so no conversion needed.

### `moduleOf`

**SML signature**: `val moduleOf : string -> trace_module`

**Crystal equivalent**: No direct equivalent. Tags are not first-class modules.

### `traceOn` / `traceOff` / `traceOnly`

**SML signatures**:

*   `val traceOn : trace_module -> unit`
*   `val traceOff : trace_module -> unit`
*   `val traceOnly : trace_module -> unit`

**Crystal equivalents**: Use filter manipulation:

```crystal
# Enable tracing for specific tag
CML::Tracer.set_filter_tags(["cml.chan"])  # Only show chan traces

# Disable tracing for specific tag (remove from filter)
CML::Tracer.set_filter_tags([])  # Show all tags

# Enable only specific tag (exclusive)
CML::Tracer.set_filter_tags(["cml.chan.send"])
```

### `amTracing`

**SML signature**: `val amTracing : trace_module -> bool`

**Crystal equivalent**: No direct equivalent. Check if tracing is enabled globally:

```crystal
{% if flag?(:trace) %}
  # Tracing is enabled at compile time
{% end %}
```

### `status`

**SML signature**: `val status : trace_module -> (trace_module * bool) list`

**Crystal equivalent**: No direct equivalent. Filter state can be inspected via `CML::Tracer` class variables.

### `trace`

**SML signature**: `val trace : (trace_module * (unit -> string list)) -> unit`

**Crystal equivalent**: `CML.trace` macro:

```crystal
CML.trace "Event.registration", pick.id, tag: "event"
```

### `watcher`

**SML signature**: `val watcher : trace_module`

Special module controlling thread termination messages.

**Crystal equivalent**: No automatic thread watching. Use manual monitoring:

```crystal
CML.spawn do
  CML::Thread.join_evt(thread_id).sync
  CML.trace "Thread.terminated", thread_id, tag: "thread_watcher"
end
```

### `watch` / `unwatch`

**SML signatures**:

* `val watch : (string * CML.thread_id) -> unit`
*   `val unwatch : CML.thread_id -> unit`

**Crystal equivalents**: Manual watching using `join_evt`:

```crystal
def watch_thread(name : String, tid : CML::Thread::Id)
  CML.spawn do
    CML::Thread.join_evt(tid).sync
    CML.trace "Thread.terminated", {name: name, tid: tid}, tag: "thread_watcher"
  end
end

def unwatch_thread(tid : CML::Thread::Id)
  # Would need to track and cancel the watcher fiber
  # Not directly supported
end
```

### `setUncaughtFn` / `setHandleFn` / `resetUncaughtFn`

**SML signatures**:

* `val setUncaughtFn : ((CML.thread_id * exn) -> unit) -> unit`
* `val setHandleFn : ((CML.thread_id * exn) -> bool) -> unit`
*   `val resetUncaughtFn : unit -> unit`

**Crystal equivalents**: Crystal has its own uncaught exception handling via `Fiber#rescue`. CML does not override this.

```crystal
# Crystal's built-in exception handling
Fiber.current.rescue do |ex|
  CML.trace "Uncaught.exception", ex, tag: "exceptions"
  # Handle or re-raise
end
```

## Thread Termination Monitoring

SML/NJ provides automatic thread termination detection. Crystal requires manual monitoring:

```crystal
# Monitor a server thread
server_tid = CML.spawn { server_loop }
watch_thread("server", server_tid)
```

## Uncaught Exception Reporting

SML/NJ allows customizing uncaught exception actions. Crystal uses fiber-level rescue blocks:

```crystal
CML.spawn do
  Fiber.current.rescue do |ex|
    CML.trace "Uncaught.exception", {ex: ex, fiber: Fiber.current}, tag: "exceptions"
    # Default: print to STDERR
    STDERR.puts "Uncaught exception in fiber: #{ex}"
  end

  # Server code that might raise
  server_loop
end
```

## Compile-Time Control

Crystal's tracing is controlled at compile time with the `-Dtrace` flag:

```bash
# Enable tracing
crystal build -Dtrace program.cr

# Disable tracing (default)
crystal build program.cr
```

When disabled, all `CML.trace` calls compile to `nil` with zero runtime overhead.

## Example Usage

**SML/NJ**:

```sml
val tm = TraceCML.traceModule (TraceCML.traceRoot, "Chan")
val _ = TraceCML.traceOn tm
val _ = TraceCML.trace (tm, fn () => ["send", Int.toString n])
```

**Crystal**:

```crystal
# Enable tracing for chan tags
CML::Tracer.set_filter_tags(["chan"])

# Trace a channel send
CML.trace "Chan.send", n, tag: "chan.send"
```

## Porting Notes

When porting SML/NJ code that uses `TraceCML`:

1.  **Trace modules**: Replace with tag-based filtering
2.  **Thread watching**: Implement manually with `join_evt`
3.  **Uncaught exceptions**: Use Crystal's `Fiber#rescue`
4.  **Output control**: Use `CML::Tracer.set_output`
5.  **Compile-time**: Remember to compile with `-Dtrace`

## See Also

*   [CML Library Reference](cml-lib.md) - Library structure containing TraceCML
*   [Crystal Tracing System](../../src/trace_macro.cr) - Implementation source
*   [CML Documentation](cml.md) - Core CML functions
*   [SML/NJ TraceCML Documentation](https://www.smlnj.org/doc/) - Original documentation

---

*Adapted from SML/NJ TraceCML documentation version 1.1 (2003-03-10)*
