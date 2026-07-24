# CML Code Review — Refactoring Opportunities

Generated from thorough static analysis of the full source tree.

---

## Critical (Fix Immediately)

### BUG-1: Race on `@@monotonic_baseline_instant` initialization
**File:** `src/cml/time_compat.cr:18-22` — **Category:** thread-safety / bug

Two concurrent fibers can both see `baseline.nil?` and both set the baseline, resetting the epoch and causing clock time travel.

```crystal
# Current
baseline = @@monotonic_baseline_instant
if baseline.nil?
  baseline = Time.instant
  @@monotonic_baseline_instant = baseline
end

# Fix: guard with mutex or use AtomicFlag double-check
```

---

### BUG-2: Broken double-checked locking on `@@event_loop_backend`
**File:** `src/cml/prim_io.cr:832-840` — **Category:** thread-safety

```crystal
# Current — first read is outside lock, ||= inside lock is not atomic with it
if backend = @@event_loop_backend
  return backend
end
@@backend_init_mtx.synchronize do
  @@event_loop_backend ||= EventLoopBackend.new
end

# Fix: move the read inside the lock
@@backend_init_mtx.synchronize do
  @@event_loop_backend ||= EventLoopBackend.new
end
```

---

## High Priority

### BUG-3: `result.cr:62` — Invalid Crystal block syntax
**File:** `src/cml/result.cr:61-63`

```crystal
# Current — broken ampersand block syntax
CML.wrap(@ivar.i_get_evt, &.unwrap)

# Fix:
CML.wrap(@ivar.i_get_evt) { |x| x.unwrap }
```

---

### BUG-4: `OnceChan` has no cleanup registration for cancelled transactions
**File:** `src/cml/once_chan.cr:64-67, 99-102`

`Blocked` lambdas store entries but never register `set_cleanup`. If a transaction is cancelled (nack/kill), the entry stays dangling, corrupting future rendezvous.

```crystal
# Add after storing the entry:
tid.set_cleanup -> { chan.send_entry = nil }
```

---

### DF-1: Massive code duplication across IO event classes
**Files:** `src/cml/prim_io.cr`, `src/cml/io.cr`, `src/cml/socket.cr`, `src/cml/stream_io.cr` — **Category:** design

All IO event classes contain identical `start_once`, `start_nack_watcher`, `deliver`, `fetch_result`, `poll`, `force_impl` boilerplate. A `NackableIOEvent(T)` abstract base class or mixin would eliminate 500+ lines.

**Affected classes:** `WaitReadableEvent`, `WaitWritableEvent`, `CompatReadEvent`, `CompatWriteEvent`, `DirectReadEvent`, `DirectWriteEvent`, `AcceptEvent`, `ConnectEvent`, `RecvEvent`, `SendEvent`, `Input1Event`, `InputAllEvent`, `InputNEvent`, `InputEvent`, and 12+ more.

---

### DF-2: 600+ lines of delegation methods in `socket.cr`
**File:** `src/cml/socket.cr:1193-1387` — **Category:** design

Homogeneous delegation to `.inner` socket objects repeated for `StreamSocket`, `UnixStreamSocket`, `UnixDatagramSocket`, `DatagramSocket`. Could be a macro or abstract protocol.

---

### ERR-1: Timer callbacks silently swallow all exceptions
**File:** `src/timer_wheel.cr:404`

```crystal
# Current — drops all exceptions
spawn { callback.call rescue nil }

# Fix: at minimum log the error
spawn { callback.call rescue |ex| Log.error { ex } }
```

---

### INC-1: IVar/MVar dead code in `cml.cr`
**File:** `src/cml.cr:1273-1291`

The IVar/MVar definitions in `cml.cr` are overwritten by `require "./cml/ivar"` and `require "./cml/mvar"` at the bottom of the file. The `cml.cr` versions are dead code. The `PutError` class at line 1288 is the only part that survives. Either remove the dead definitions or consolidate to one location.

---

## Medium Priority

### DF-3: Redundant macro-generated choose/select overloads
**File:** `src/cml.cr:1358-1413` — **Category:** design

`generate_heterogeneous_choose_overloads(12)` and `generate_heterogeneous_select_overloads(12)` create 22 method overloads. The varargs versions at lines 1379/1448 already handle arbitrary counts. The macro overloads add compile time with minimal benefit.

---

### DF-4: `timer_wheel.cr` has hardcoded tick-duration assumptions
**File:** `src/timer_wheel.cr:362,369-374`

`advance_internal` converts argument `.milliseconds` to `Time::Span` but applies it as ticks, assuming `@tick_duration == 1ms`. The fallback sleep values (1ms, 100ms) are also hardcoded independently of `@tick_duration`.

---

### PERF-1: Per-sync array allocation in `sync_on_base_events`
**File:** `src/cml.cr:1087` — **Category:** perf

`blocked = Array(Blocked(T)).new` allocated every sync call. For the dominant 1-3 event case, could use a pre-allocated inline buffer or Tuple.

---

### TS-1: `sync_on_base_events` retry path re-reads state inconsistently
**File:** `src/cml.cr:1112-1119` — **Category:** thread-safety

After `Fiber.suspend`, the code checks `tid.cancelled?` but cancels may race between the fiber being enqueued and it starting execution. Re-fetch `Thread::Id.current` if state could have changed.

---

### TS-2: Spawn inside mutex in `cleanup.cr`
**File:** `src/cml/cleanup.cr:93-96` — **Category:** thread-safety

`clean(time)` spawns a fiber for each hook inside `protect`'s mutex. A narrow window exists where a second `clean` call interleaves.

---

### ERR-2: Overbroad `rescue` in tuple-space accept loop
**File:** `src/cml/tuple.cr:1041`

```crystal
rescue  # catches ALL exceptions including NoMemoryError
  # Keep server loop alive on transient accept/decode errors.
end
```

Narrow to `IO::Error | Socket::Error`.

---

### INC-2: Mixed `spawn` forms throughout codebase
**Files:** multiple — **Category:** inconsistency

Three spawn forms used inconsistently: `CML.spawn` (managed), `::spawn` (raw), `spawn` (ambiguous). Standardize on explicit intent.

---

### INC-3: `AtomicFlag` vs raw `Atomic(Bool)` inconsistency
**Files:** multiple — **Category:** inconsistency

`AtomicFlag` (with acquire/release fences) is defined but raw `Atomic(Bool)` is used in several places (e.g., spec files, internal channel state). Standardize on the wrapper class.

---

### SMELL-1: Extensive `.as(T)` cast usage without runtime safety
**Files:** `src/cml/imperative_io.cr` and others — **Category:** code-smell

Patterns like `val.as(V)` and `group.as(BaseGroup(T))` fail with opaque runtime errors on type mismatch. Prefer `case ... when` exhaustiveness or type-narrowing methods.

---

### SMELL-2: Unconditional `Fiber.yield` in `Mailbox#send`
**File:** `src/cml/mailbox.cr:46` — **Category:** code-smell

Hardcoded `Fiber.yield` after every send forces context switch with no documented rationale. If for fairness, document it; otherwise remove.

---

### SMELL-3: Global monkey-patching of `TCPSocket`/`UNIXSocket`
**File:** `src/cml/socket.cr:6-19` — **Category:** code-smell

Defines `from_handle` globally. Conflicts with any other shard that also patches these classes. Move to extension methods or utility namespace.

---

### SPEC-1: Sleep-based synchronization in specs
**File:** `spec/cml_spec.cr` (lines 56, 74, 154, 195, 449, 748, 761, 906-912) — **Category:** test-fragility

Specs use `sleep`/`Fiber.yield` as synchronization, making the suite timing-dependent. Replace with channel or IVar handoff for deterministic tests.

---

### SPEC-2: Over-wide timeout tolerances
**File:** `spec/cml_spec.cr:284-287` — **Category:** test-quality

50ms timeout accepts 500ms upper bound. Tighten to catch 2-3x regressions.

---

### EXP-1: `execution_context.cr` fallback `wait` is a no-op
**File:** `src/cml/execution_context.cr:25-26`

Non-MT fallback `wait` method does nothing — callers expecting blocking until completion will proceed immediately, never executing spawned work.

---

## Low Priority

| # | File:Line | Description |
|---|-----------|-------------|
| DF-4 | `cml.cr:1288-1292` | `PutError` shared between IVar and MVar — split into separate types |
| BUG-5 | `trace_macro.cr:85-92` | `should_trace?` dead code when `-Dtrace` not passed |
| TS-3 | `cml.cr:376-403` | Manual fence-based `AtomicFlag` — consider making get/set always ordered |
| PERF-2 | `timer_wheel.cr:260-271` | Speculative array allocations on every timer tick slot |
| PERF-3 | `src/cml/prim_io.cr:341` | `.dup` on data Bytes in every send event |
| ERR-3 | `cleanup.cr:107-108` | Bare rescue on `unlog_channel` swallows unexpected errors |
| ERR-4 | `imperative_io.cr:217-220` | Silent `pos=` failure |
| INC-4 | multiple | Mixed reentrant/non-reentrant mutex creation |
| SMELL-4 | `cleanup.cr:263-271` | Dead `raise_on_duplicate` parameter |
| SMELL-5 | `barrier.cr:205-206` | Stringly-typed barrier errors |
| SMELL-6 | `imperative_io.cr` | Compile-time `{% raise %}` for unsupported types |
| SMELL-7 | `cml.cr:368-370` | `get_if_present` returns `{Bool, T?}` when `T?` would suffice |
| SMELL-8 | `prim_io.cr:857-864` | Unguarded type reference in compile-time conditional |

---

## Summary

| Severity | Count |
|----------|-------|
| Critical | 2 |
| High | 7 |
| Medium | 14 |
| Low | 15 |
| **Total** | **38** |
