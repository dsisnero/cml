# Review of `plans/refactor.md`

Reviewed against the current tree on 2026-05-29. All claims verified against actual source code.

## Overall assessment

The original refactor.md identifies several real concurrency and maintenance issues but contains four false positives and two overstated claims. The review below separates findings into verified bugs, false positives, items needing stronger proof, and design debt.

---

## Confirmed bugs

### 1. BUG-1: `time_compat.cr` baseline initialization race — REAL

**Verdict: confirmed bug (thread-safety)**

- `src/cml/time_compat.cr:18-22` initializes `@@monotonic_baseline_instant` without synchronization.
- Under `-Dpreview_mt`, two threads can both observe `nil`, install different baselines, and cause monotonic time to move backward.

```crystal
# src/cml/time_compat.cr:18-22
baseline = @@monotonic_baseline_instant
if baseline.nil?
  baseline = Time.instant
  @@monotonic_baseline_instant = baseline
end
```

Additional note: `@@monotonic_baseline_ms` (line 9) is initialized to `0_u64` and never written again. The variable appears unused in practice since `baseline_ms` at line 23 always reads `0`. This may be dead code from an incomplete reset-baseline feature.

### 2. BUG-2: Double-checked locking in `prim_io.cr` — REAL (two instances)

**Verdict: confirmed bug, refactor.md only found one of two**

- `src/cml/prim_io.cr:831-841` — `event_loop_backend` reads `@@event_loop_backend` outside the mutex.
- `src/cml/prim_io.cr:843-853` — `io_evented_backend` has the identical pattern.
- Both share `@@backend_init_mtx` (line 813).

Under `-Dpreview_mt`, a thread could read a partially-constructed backend object from the fast path. The fix is either to always acquire the mutex, or to use an `Atomic` pointer with appropriate ordering.

### 3. ERR-1: Timer callbacks swallow exceptions — REAL

**Verdict: confirmed**

- `src/timer_wheel.cr:404` — `spawn { callback.call rescue nil }` silently discards all errors.
- Makes debugging timer-driven behavior extremely difficult.

Whether the fix is logging, a tracer hook, or a configurable error sink is a design choice, but the current blanket rescue is a real problem.

---

## False positives in refactor.md

### 1. BUG-3: `result.cr` block syntax — NOT A BUG

**Verdict: refactor.md is wrong**

`src/cml/result.cr:62` uses:

```crystal
CML.wrap(@ivar.i_get_evt, &.unwrap)
```

This is valid Crystal. `CML.wrap` is defined at `src/cml.cr:1348` as:

```crystal
def self.wrap(evt : Event(A), &f : A -> B) : Event(B) forall A, B
```

The `&.unwrap` shorthand creates the block `{ |x| x.unwrap }`, which is passed as the `&f` parameter. This compiles without error.

### 2. BUG-4: `OnceChan` cleanup — OVERSTATED

**Verdict: not a corruption bug; by-design behavior**

The claim that "the entry stays dangling, corrupting future rendezvous" is wrong. `OnceChan` explicitly documents its design at `src/cml/once_chan.cr:5,11`:

- Line 5: *"no queuing, no fairness tracking, and no cleanup registration"*
- Line 11: *"No TransactionId cleanup (at most one entry; cancel unused)"*

The rendezvous paths check `tid.active?` before committing (lines 54, 89), so stale entries from cancelled transactions are ignored. Since `OnceChan` is single-use by contract (line 18: "exactly one send/receive pair"), entry retention is bounded and harmless.

There is a theoretical memory retention issue if many `OnceChan` instances are created but never complete rendezvous, but that is a GC concern, not a correctness bug.

### 3. INC-1: "Dead IVar/MVar definitions in cml.cr" — WRONG

**Verdict: refactor.md is wrong**

`src/cml.cr:1273-1292` contains:
- A comment header describing IVar (SML signature)
- The `PutError` class (lines 1288-1292)

There are **no duplicate `IVar` or `MVar` class definitions**. The actual implementations live solely in `src/cml/ivar.cr:3` and `src/cml/mvar.cr:3`. `grep` confirms no other `class IVar` or `class MVar` definitions exist in the codebase.

At most, the comment header at line 1273 is a misleading section boundary. The `PutError` class is the only code there and is actively used.

### 4. DF-3: Heterogeneous choose/select overloads "redundant" — WRONG

**Verdict: refactor.md is wrong; the overloads are necessary**

The refactor.md claims the macro-generated overloads at `src/cml.cr:1358-1377` and `1396-1413` are redundant because varargs versions exist.

The varargs versions (lines 1390-1392) are:

```crystal
def self.choose(*events : Event(T)) : Event(T) forall T
```

This requires **all events to be the same type `T`**. Calling `choose(Event(Int32).new, Event(String).new)` would fail to unify `T`.

The macro overloads generate signatures like `choose(event1 : Event(T1), event2 : Event(T2))` and wrap each event to the union type `Event(T1 | T2)`. Without them, heterogeneous `choose` calls lose proper union typing. These overloads are essential.

### 5. TS-1: `sync_on_base_events` re-read inconsistency — WRONG

**Verdict: refactor.md is wrong; the code already does this correctly**

`src/cml.cr:1111-1120` shows a four-step re-validation after `Fiber.suspend`:

```crystal
Fiber.suspend                            # line 1111
current_tid = Thread::Id.current         # line 1112 — re-fetches thread ID
current_tid.wait_if_suspended            # line 1113 — checks thread state
if current_tid.killed?                   # line 1114 — checks kill status
  raise Thread::Killed.new
end
if tid.cancelled?                        # line 1117 — checks transaction cancel
  return sync_on_base_events(events)     # retry
end
```

The code explicitly re-reads `Thread::Id.current`, checks lifecycle state, checks transaction cancellation, and re-queries all events. The refactor.md claim appears based on an outdated reading.

### 6. EXP-1: `ExecutionContext#wait` fallback is a no-op — NOT A BUG

**Verdict: documented design choice, not a bug**

`src/cml/execution_context.cr:16-17` explicitly documents:

```crystal
# Fallback context for builds without multithreaded execution contexts.
# `spawn` uses the default scheduler and `wait` is a no-op.
```

`spec/execution_context_spec.cr:15-27` tests this behavior. The fallback `wait` is intentionally empty because, without execution contexts, spawned fibers run on the default scheduler and there is no join semantic to wait on. This is a deliberate design decision, not a correctness gap.

---

## Claims needing stronger proof

### 1. TS-2: `Cleanup.clean` spawning inside the mutex

**Verdict: the stated concern is misdirected; the real issue is elsewhere**

The refactor.md says spawning inside the mutex is a thread-safety bug. That specific claim is wrong — `spawn` is non-blocking and merely schedules a fiber. The mutex is held only during the `select` and `spawn` loop, not during callback execution.

However, there **is** a real concern that the spawned cleaner callbacks (e.g., `clean_channels`, `start_servers`, `shutdown_servers`) access `@@chan_items`, `@@mbox_items`, and `@@server_items` **without holding the mutex**. This is a genuine data race if another thread concurrently modifies those arrays.

Additionally, the `protect` method's guard `CML.running?` is read outside the mutex (`src/cml/cleanup.cr:49`), creating a TOCTOU race if the runtime state toggles concurrently.

Severity: worth fixing, but the fix target is the unprotected shared array access in spawned callbacks, not the spawn-inside-mutex pattern itself.

### 2. SMELL-2: `Mailbox#send` unconditional `Fiber.yield`

**Verdict: likely deliberate; needs investigation before removal**

`src/cml/mailbox.cr:46` yields after every send. Looking at the surrounding code (lines 41-44), `resume_fiber` is called on the matched receiver just before the yield. The yield gives the resumed receiver fiber an opportunity to run, preventing sender starvation of the scheduler.

Before removing this, verify whether mailbox fairness or receiver liveness depends on it. A test that sends 1000 messages without yields and checks receiver progress would answer the question.

### 3. INC-3: `AtomicFlag` vs raw `Atomic(Bool)`

**Verdict: style concern, not a correctness issue**

`AtomicFlag` provides acquire/release semantics, but not every boolean atomic needs full ordering. For example, `Chan#@closed` (`src/cml.cr:428`) using `Atomic(Bool)` may be intentionally relaxed. If the argument is consistency/auditability, frame it as a style cleanup, not a bug risk.

---

## Confirmed design debt

### 4. DF-1: IO event implementation duplication — REAL

`src/cml/prim_io.cr`, `src/cml/io.cr`, `src/cml/socket.cr`, and `src/cml/stream_io.cr` repeat the same lifecycle: `poll -> Blocked -> start_once -> nack watcher -> deliver -> fetch_result`. A `NackableIOEvent(T)` base class or mixin would reduce duplication significantly.

Caution: these events differ in IO wait strategy, result shape, and cancellation semantics. An inheritance refactor is easy to get wrong. Extract shared behavior incrementally, starting with the most common pattern.

### 5. DF-2: Socket delegation boilerplate — REAL

`src/cml/socket.cr:1193-1387` contains a large block of forwarding methods to `.inner`. Valid refactoring material (macro-generated delegation or `delegate` macro). Not urgent.

### 6. SPEC-1/SPEC-2: Spec timing fragility — REAL

`spec/cml_spec.cr` uses `sleep`/`Fiber.yield` for synchronization and over-wide timeout tolerances (e.g., 50ms timeout accepting up to 500ms). Replace with channel or IVar handoff for deterministic tests. Tighten timeout bounds to catch 2-3x regressions.

### 7. ERR-2: Overbroad rescue in tuple-space — REAL

`src/cml/tuple.cr:1041` catches all exceptions. Narrow to `IO::Error | Socket::Error`.

### 8. Remaining medium/low items

The following items from refactor.md are directionally correct and do not require correction:

- **INC-2** (mixed spawn forms) — real inconsistency, style cleanup
- **SMELL-1** (`.as(T)` casts) — real code smell, worth addressing
- **SMELL-3** (global monkey-patching of TCPSocket/UNIXSocket) — real conflict risk
- **DF-4** (timer_wheel hardcoded tick assumptions) — real, minor
- **PERF-1** (per-sync array allocation) — real, minor optimization opportunity
- **Low-priority table items** — all directionally correct

---

## What both documents missed

### 1. `@@monotonic_baseline_ms` appears to be dead code

`src/cml/time_compat.cr:9` initializes `@@monotonic_baseline_ms = 0_u64`, and line 23 reads it as `baseline_ms = @@monotonic_baseline_ms`. But no code ever writes a non-zero value. The final expression at line 25 is always `0 + elapsed.total_milliseconds.to_u64`, making `baseline_ms` a no-op addend. This may be a vestige of an unfinished baseline-reset feature.

### 2. `protect` TOCTOU race on `CML.running?`

As noted in TS-2 above, `src/cml/cleanup.cr:49` reads `CML.running?` outside the mutex. If the running state toggles concurrently, one thread enters the protected path while another runs unprotected, causing a data race on shared arrays.

---

## Corrected severity summary

| Category | Count | Items |
|----------|-------|-------|
| Confirmed bugs | 3 | BUG-1, BUG-2 (x2), ERR-1 |
| False positives in refactor.md | 6 | BUG-3, BUG-4, INC-1, DF-3, TS-1, EXP-1 |
| Needs stronger proof | 3 | TS-2 (reframed), SMELL-2, INC-3 |
| Design debt | 8+ | DF-1, DF-2, SPEC-1/2, ERR-2, INC-2, SMELL-1, SMELL-3 |
| Newly identified | 2 | dead `baseline_ms`, `protect` TOCTOU |

## Recommended priority order

### A. Fix first (confirmed correctness bugs)

1. `time_compat.cr` baseline initialization race (BUG-1)
2. Unsafe DCL in `prim_io.cr` — both `event_loop_backend` and `io_evented_backend` (BUG-2)
3. Swallowed exceptions in `timer_wheel.cr` (ERR-1)

### B. Investigate with reproducer before changing

4. `cleanup.cr` unprotected shared array access in spawned callbacks + `protect` TOCTOU (TS-2 reframed)
5. `OnceChan` retention under heavy cancellation (BUG-4 — test, not fix blindly)
6. `Mailbox#send` fairness yield (SMELL-2 — benchmark before removing)

### C. Refactor after correctness work is done

7. IO event boilerplate extraction (DF-1)
8. Socket delegation compression (DF-2)
9. Spec timing cleanup (SPEC-1/SPEC-2)
10. Overbroad rescue in tuple-space (ERR-2)
11. Style cleanups (INC-2, INC-3, SMELL-1, SMELL-3)
