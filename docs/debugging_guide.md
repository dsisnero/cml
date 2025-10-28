# CML Debugging Guide

This guide explains how to use the CML tracing system to debug code that is not working as expected—whether due to logic bugs, race conditions, or performance issues.

## Overview

CML's tracing system provides deep visibility into event registration, commit/cancel outcomes, fiber context, and channel operations. It is designed for both correctness debugging and performance analysis.

## Enabling Tracing

Compile with the `-Dtrace` flag to enable all trace points:

```bash
crystal run your_program.cr -Dtrace
```

## Using User-Defined Tags

Add a `tag:` argument to any `CML.trace` call to group or filter trace output:

```crystal
CML.trace "Chan.register_send", value, pick, tag: "chan"
CML.trace "Pick.committed", event_id, value, tag: "pick"
```

Tags help you focus on specific operations or code regions.

## Filtering Trace Output

Filter trace output by tag, event type, or fiber:

```crystal
# Only show traces with the tag "chan" or "pick"
CML::Tracer.set_filter_tags(["chan", "pick"])

# Only show traces for a specific event type
CML::Tracer.set_filter_events(["Chan.register_send", "Pick.committed"])

# Only show traces for a specific fiber (by name or id)
CML::Tracer.set_filter_fibers(["my_fiber_name"])
```

## Redirecting Trace Output

By default, trace output goes to STDOUT. Redirect it to a file or any IO:

```crystal
CML::Tracer.set_output(File.open("trace.log", "w"))
```

## Debugging Scenarios

### 1. Finding Stuck or Slow Events
- Tag and filter all send/receive operations on a channel.
- Look for missing or delayed `committed`/`cancelled` outcomes.

### 2. Diagnosing Race Conditions
- Assign fiber names with `CML::Tracer.set_fiber_name("worker1")`.
- Filter traces by fiber to see interleaving and event order.

### 3. Verifying Correctness
- Trace all `Pick.committed` and `Pick.cancelled` events.
- Ensure only one event in a choice is committed (CML invariant).

### 4. Reducing Trace Noise
- Use tags and event filters to focus on the subsystem or operation of interest.
- Redirect output to a file for offline analysis.

## Real-World Trace Usage Examples

### Example 1: Debugging a Stuck Channel
Suppose a sender or receiver is stuck and not completing:

```crystal
CML.trace "Chan.register_send", value, pick, tag: "chan"
CML.trace "Chan.send_committed", value, pick, tag: "chan"
CML.trace "Chan.send_cancelled", value, pick, tag: "chan"
CML::Tracer.set_filter_tags(["chan"])
CML::Tracer.set_output(File.open("trace.log", "w"))
```

Run your program and inspect `trace.log` for missing or delayed `send_committed` events.

### Example 2: Tracking a Specific Fiber
If you want to follow a particular fiber's actions:

```crystal
CML::Tracer.set_fiber_name("worker1") # Call at fiber start
CML.trace "Pick.committed", event_id, value, tag: "pick"
CML::Tracer.set_filter_fibers(["worker1"])
```

### Example 3: Isolating a Subsystem
If you have multiple subsystems, tag each:

```crystal
CML.trace "Timer.start", timer_id, tag: "timer"
CML.trace "MVar.put", value, tag: "mvar"
CML::Tracer.set_filter_tags(["timer"])
```

### Example 4: Debugging Choice Outcomes
To ensure only one event in a choice is committed:

```crystal
CML.trace "Pick.committed", event_id, value, tag: "pick"
CML.trace "Pick.cancelled", event_id, tag: "pick"
CML::Tracer.set_filter_tags(["pick"])
```

Check that for each choice, only one `committed` event appears per group of related event IDs.

## Best Practices
- Use tags to isolate and group related trace points.
- Filter by tag or event to reduce noise and focus on the problem.
- Use fiber names to track specific concurrent operations.
- Always disable tracing in production for zero overhead.

## Reference
- See `src/trace_macro.cr` for tracing implementation and API.
- See the Benchmarking Guide for performance-focused tracing tips.
- See the README for general usage and API documentation.
