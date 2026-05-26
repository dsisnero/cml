# CML Optimization Plan

Based on: *"Toward Optimization of Concurrent ML"* — Reppy & Xiao (University of Chicago)

The paper presents static analysis to classify channel communication topology:
one-shot, point-to-point, fan-out, fan-in. The classified channels can then
use specialized (faster) implementations. Below are concrete ideas for our
Crystal CML codebase, organized by effort and impact.

---

## Baseline Measurements (2026-05-25, Release mode, Apple M3 Max)

Captured with `CRYSTAL_WORKERS=1 --release --no-debug`.
Stored in `perf/baseline-20260525-213346/`.

### Hot Path Benchmarks (`benchmarks/hot_path_bench.cr`)

| Operation | ns/op | ops/s |
|-----------|-------|-------|
| `sync(always)` | 39.6 | 25,260,845 |
| `choose(always, never)` | 67.6 | 14,799,987 |
| `choose(always, timeout)` | 885.3 | 1,129,589 |
| channel rendezvous (2 fibers) | 5,250.5 | 190,458 |
| timeout schedule+cancel | 1,755.9 | 569,500 |
| tuple out/in round trip | 41,178.8 | 24,284 |

**Key observations:**
- `sync(always)` at ~40ns is the baseline overhead of the sync machinery
- `choose(always, timeout)` at 885ns is ~13x slower than `choose(always, never)` — the timer wheel scheduling dominates
- Channel rendezvous at 5.2us per op — fiber spawn + sync + channel mechanics
- Tuple operations at 41us are the slowest primitive

### Event Creation Overhead (`benchmarks/cml_benchmarks.cr`, partial)

| Event | ips | ns/op | alloc/op |
|-------|-----|-------|----------|
| `NeverEvt` | 11.96M | 83.6 | 112B |
| `GuardEvt` | 11.26M | 88.8 | 80B |
| `SendEvt` | 8.08M | 123.8 | 112B |
| `AlwaysEvt` | 6.54M | 152.9 | 160B |
| `RecvEvt` | 5.38M | 186.0 | 240B |
| `WrapEvt` | 5.06M | 197.6 | 224B |
| `TimeoutEvt` | 3.20M | 312.6 | 320B |

**Key observations:**
- `TimeoutEvt` is 2x slower to create than `AlwaysEvt` and allocates 3x more — the TimerWheel infrastructure is expensive up front
- `RecvEvt` allocates 240B because `make_recv_poll` creates both a `Slot(T)` and an `AtomicFlag`
- `WrapEvt` allocates 224B from lambda capture

### Timer Wheel Benchmarks (`benchmarks/timer_wheel_benchmark.cr`)

| Operation | avg (ms) | min (ms) | max (ms) |
|-----------|----------|----------|----------|
| Schedule 10K short timers | 1.006 | 0.774 | 1.919 |
| Schedule 10K mixed timers | 0.816 | 0.786 | 0.897 |
| Schedule+cancel 5K | 0.487 | 0.439 | 0.527 |
| Execute 1K via advance | 0.116 | 0.093 | 0.194 |
| Schedule 1K intervals | 0.091 | 0.068 | 0.179 |

**Key observations:**
- Schedule+cancel is ~50ns per timer (5K in 0.487ms). Dominated by `TimeoutEvent.start_once` + `try_cancel` overhead.
- Pure schedule (no cancel) is ~100ns per timer.

### Broken Benchmarks (noted for repair)

| File | Issue |
|------|-------|
| `cml_benchmarks.cr:55-70` | Single-fiber channel rendezvous hangs — both send and recv block with no other fiber to rendezvous |
| `mvar_benchmark.cr` | References `MVarOptimized` class that doesn't exist; stale import path `../src/mvar` |
| `mailbox_benchmark.cr` | Requires `mailbox_bounded.cr` and `mailbox_lockfree.cr` which don't exist |
| `multicast_benchmark.cr` | Untested — likely stale imports similar to mailbox_bench |

---

## Category A: Runtime Specializations (no static analysis required)

These add user-visible constructors for specialized channels. The user declares
topology intent; the runtime uses a lighter implementation.

### A1. One-Shot Channel (`Chan.once`)

**Paper insight:** "One-shot" channels are used for exactly one send. No queuing,
no fairness, no nack support needed.

**Implementation:** `src/cml/harness.cr:100` (rpc_client already creates single-use
channels internally). Make this a first-class primitive.

```crystal
# Current: full-featured channel with Deque-backed send/recv queues
ch = CML::Chan(Int32).new

# Proposed: single-use channel, no queues needed
ch = CML::Chan(Int32).once  # or CML::OnceChan(Int32).new
```

**Gains:**
- Eliminates Deque allocation and mutex contention on send/recv queues
- No TransactionId cleanup registration (no `set_cleanup`)
- No fairness priority tracking
- Estimated 2-4x throughput for RPC-style patterns

**Files:** New file `src/cml/once_chan.cr` or extend `Chan` with mode flag.

**Work estimate:** 2-3 hours (small new class, mirroring Chan but simpler).

### A2. Point-to-Point Channel (`Chan.p2p`)

**Paper insight:** Single sender + single receiver means no contention on either
queue. One writer, one reader.

**Implementation:** Atomic slot + event pair instead of Deque-based queues.

```crystal
ch = CML::Chan(Int32).p2p
```

**Gains:**
- Replace `Deque({T, AtomicFlag, TransactionId})` with a single `{T?, AtomicFlag}?` slot
- No iteration through queue entries (no `while entry = q.shift?`)
- Single CAS for rendezvous instead of mutex-protected queue

**Files:** `src/cml/chan.cr` (new file, extracted from cml.cr) or mode flag.

**Work estimate:** 3-4 hours.

### A3. Choice-Free Channel Optimization

**Paper insight:** "A channel that is not used in choice contexts can have
a simpler, and more efficient, implementation" — no nack support needed.

The key overhead in our current implementation is `src/cml.cr:1166-1218`
(`sync_on_complex_group`) which handles nack signaling. Choice-free channels
skip this path entirely.

**Implementation:** Track whether a channel is ever used in `CML.choose`. If not,
use a fast path in `force_impl` that returns `BaseGroup` directly instead of
going through `sync_on_complex_group`. Currently this is already somewhat
handled since `SendEvent` and `RecvEvent` return `BaseGroup` from `force_impl`
— but the nack infrastructure in `sync_on_complex_group` is only triggered
when `ChooseEvent` or `WithNackEvent` is in the tree. The fast path exists
(`sync_on_base_events`) and is used when there are no nacks.

**What to do:** Add a method on `Chan` to eagerly check "am I in a choice context?"
and skip even the overhead of collecting nack flags during `collect_events`.

**Gains:** 5-15% improvement on non-choice send/recv (avoid nack flag collection).

**Work estimate:** 2 hours (small refactor in sync path).

### A4. Fan-Out / Fan-In Channels

**Paper insight:** Known multi-sender/single-receiver or single-sender/multi-receiver
patterns allow specialized internal data structures.

**Implementation:**
- **Fan-in** (many senders, one receiver): Use a lock-free MPSC queue for send_q
- **Fan-out** (one sender, many receivers): Use broadcast slot (one write, many reads)

```crystal
ch = CML::Chan(Int32).fan_in
ch = CML::Chan(Int32).fan_out
```

**Gains:** Better scaling under contention for the many-producer or many-consumer case.

**Work estimate:** 5-8 hours (MPSC and broadcast implementations).

---

## Category B: Implementation-Level Optimizations

Changes to existing internals; no API changes.

### B1. Lock-Free TransactionId

**Current:** `TransactionId` (`src/cml.cr:82-178`) uses `Atomic(TransactionState)`
for the state but `Sync::Mutex` for cleanup and fiber fields.

**Proposed:** Make `@cleanup` and `@fiber` use `Atomic` pointers or lock-free
compare-and-swap patterns, eliminating mutex overhead in the hot path.

**Gains:** Reduced latency per sync operation. Every `CML.sync` creates a
`TransactionId`, sets its fiber, and potentially sets cleanup. Mutex overhead
per operation is ~50-200ns.

**Work estimate:** 4 hours (careful lock-free programming required).

### B2. Poll-First Fast Path

**Current:** `sync_on_base_events` (`src/cml.cr:1070`) iterates all events,
polls each, and if all blocked creates a TransactionId and registers block fns.

**Proposed:** Add a thread-local cache of the last N event poll results to
avoid re-polling events that were just checked. Also: when there are many
blocked events, batch the block_fn registration into a single pass.

**Gains:** 10-20% for `choose` with many branches.

**Work estimate:** 3 hours.

### B3. Slot Pooling

**Current:** Every `Chan#make_send_poll` and `Chan#make_recv_poll` allocates
a new `Slot(T)` and `AtomicFlag` per operation (`src/cml.cr:335-373, 526-601`).

**Proposed:** Pre-allocate slots in the Chan for the active send/recv pair.
A point-to-point channel only needs one send slot and one recv slot total.

**Gains:** Reduced GC pressure, fewer allocations per sync.

**Work estimate:** 2 hours (for point-to-point; general case harder).

### B4. Timer Wheel Optimizations

**Current:** `TimeoutEvent` (`src/cml.cr:888-988`) schedules timer callbacks
individually. For many concurrent timeouts, timer wheel overhead adds up.

**Proposed:** Batch timer scheduling/delivery. If multiple fibers block on
timeout events close together, schedule a single timer and wake all.

**Gains:** Better scalability for programs with many concurrent timeouts
(e.g., connection pools, rate limiters).

**Work estimate:** 4 hours.

### B5. Priority-Selection Index

**Current:** `sync_on_base_events` iterates all events linearly to find the
highest-priority enabled event.

**Proposed:** Maintain an ordered structure (binary heap or intrusive linked
list sorted by priority) in the `BaseGroup`, so the highest-priority enabled
event is found in O(1) instead of O(n).

**Gains:** Significant for `choose` with many branches (10+).

**Work estimate:** 3 hours.

---

## Category C: Static Analysis / Compile-Time

Longer-term efforts, inspired by the paper's CFA + CFG approach.

### C1. Macro-Based Topology Detection

Use Crystal macros to trace where `Chan` instances flow at compile time:

```crystal
{% if channel_has_single_sender?(ch) %}
  # Use optimized send path
{% end %}
```

This is a simplified version of the paper's Type-Sensitive CFA. Crystal macros
operate on the AST, so we can detect: how many `send` calls reach a given
channel variable, whether it escapes into closures, etc.

**Scope:** Limited to within-file analysis initially (cross-module requires
link-time optimization which Crystal doesn't support).

**Work estimate:** 8-12 hours (feasibility study first).

### C2. Choice-Context Detection Macro

Detect whether a channel is ever passed to `CML.choose` at compile time.
If not, generate code that skips nack infrastructure.

```crystal
# At compile time: if ch is never in choose(), use fast path
{% if !channel_in_choose?(ch) %}
  # Direct send/recv without nack overhead
{% end %}
```

**Work estimate:** 4-6 hours.

### C3. Channel Lifetime Analysis

Detect when a channel is used for exactly one send (one-shot pattern) at compile
time, and automatically substitute the optimized implementation.

**Work estimate:** 6-8 hours.

---

## Category D: Benchmarking Infrastructure

Before optimizing, we need reproducible benchmarks.

### D1. Micro-Benchmarks for Channel Operations

Add benchmarks for:
- Single send/recv throughput
- Many-to-one fan-in throughput
- One-to-many fan-out throughput
- `choose` with N branches
- RPC round-trip latency (channel create + send + recv)
- Timeout scheduling/delivery

**File:** `benchmarks/channel_topology_bench.cr`

### D2. Harness Throughput Benchmarks

Benchmark the harness implementations from `src/cml/harness.cr` with varying
depths and data sizes to measure scaling.

**File:** `benchmarks/harness_bench.cr`

---

## Experiment Tracking

Each optimization attempt gets an experiment ID, before/after numbers, and
a keep/discard decision. Negative results are preserved to prevent retries.

### EXP-001: Baseline capture (2026-05-25)
- **Command**: `crystal run --release --no-debug benchmarks/hot_path_bench.cr`
- **Result**: captured, stored in `perf/baseline-20260525-213346/`
- **Decision**: N/A (baseline)

---

## Priority Order (updated from baseline data)

| Priority | Item | Hot Path Targeted | Impact | Effort | Risk |
|----------|------|-------------------|--------|--------|------|
| 1 | A1 One-Shot Channel | `sync` → 40ns (skip queues) | High | Low | Low |
| 2 | A2 Point-to-Point Channel | `rendezvous` → 5.2us (CAS instead of Deque) | High | Medium | Low |
| 3 | D1 Fix broken benchmarks | Make measurement path reliable | High | Low | None |
| 4 | A3 Choice-Free Fast Path | `choose(always, never)` → 68ns (skip nack collect) | Medium | Low | Low |
| 5 | B3 Slot Pooling | `RecvEvt` creation → 240B alloc (reuse slots) | Medium | Low | Low |
| 6 | B1 Lock-Free TransactionId | `sync` → 40ns (−mutex overhead) | Medium | Medium | Medium |
| 7 | B5 Priority-Selection Index | `choose` with N branches → O(log n) | Medium | Medium | Low |
| 8 | B2 Poll-First Fast Path | `sync_on_base_events` iteration | Low | Medium | Low |
| 9 | B4 Timer Wheel Batching | `timeout schedule+cancel` → 1.7us | Low | High | Medium |

---

## Next Steps (ordered)

1. **Fix broken benchmarks** so the measurement path is reliable
   - Remove `MVarOptimized` references from `mvar_benchmark.cr` (keep only standard MVar)
   - Create stub `mailbox_bounded.cr` and `mailbox_lockfree.cr` or remove those benchmarks
   - Fix single-fiber rendezvous in `cml_benchmarks.cr` (add spawn or remove test)
2. **Implement one-shot channel** (`Chan.once`) — highest impact, lowest effort
3. **Capture EXP-002**: measure one-shot vs standard channel for RPC patterns
4. **Implement point-to-point channel** (`Chan.p2p`)
5. **Capture EXP-003**: measure p2p vs standard channel for rendezvous
