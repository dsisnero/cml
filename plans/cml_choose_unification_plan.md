# CML Choose/Select Unification and Event Typing Fix Plan

## Overview
This plan addresses the recurring type and overload errors in the `choose` and `select`
implementations of the Crystal CML runtime. The root issue is **type unification between
heterogeneous event types** (e.g., `Event(T)` vs. `Event(Void)` or `GuardEvt(Nil)`).
The system currently relies on Crystal’s overload resolution, which is both verbose and
fragile when handling union-type inference dynamically.

We will transition toward a more unified, macro-driven approach to preserve the
semantic correctness of Concurrent ML (CML) while making the Crystal implementation
compile cleanly, support arbitrary event shapes, and remain ergonomic for users.

---

## Current Issues

### 1. Overload Explosion
There are too many hand-written `choose` overloads to handle common cases like:

```crystal
CML.choose(evt1 : Event(T), evt2 : Event(Void))
CML.choose(evt1 : Event(T), evt2 : Event(T), evt3 : Event(Void))
CML.choose(evt1 : Event(T), evt2 : Event(T))
```

This makes the compiler brittle, creates ambiguity for mixed-type arrays, and leads
to unclear errors when inference cannot find a single matching overload.

### 2. Missing Type Unification Logic
CML events like `GuardEvt(Nil)` or `TimeoutEvt(Symbol)` fail when passed together because
Crystal’s type system doesn’t allow late unification of event result types. The error:

```
Error: expected argument #1 to 'CML.choose' to be Array(CML::Event(Symbol)),
not Array(CML::AlwaysEvt(Symbol) | CML::GuardEvt(Nil))
```

shows that array type deduction fails when not all elements have the same result type.

### 3. `select` and `choose` Divergence
The `select` sugar layer mirrors `choose`, but duplicating its overloads adds redundancy.
Maintaining both requires error-prone synchronization of signatures.

### 4. Complex `AnyEvent` vs `Event(T)` Hierarchy
The `AnyEvent` superclass was introduced to allow unified storage of control and typed
events. However, Crystal’s generic constraints make it difficult to use without excessive
casting or unsafe macros.

### 5. No Enforcement of Minimum Arity
CML semantics require at least two alternatives in a `choose` — otherwise, it degenerates
into a simple `sync`. Currently, this is unchecked.

---

## Proposed Solution

### Step 1 — Introduce Abstract Module `EventLike`
Instead of subclassing `Event(T)` or introducing `AnyEvent`, define an **abstract module**
that captures common behavior without generics:

```crystal
module EventLike
  abstract def try_register(pick)
  abstract def poll : _
end
```

Then, make `Event(T)` and `ControlEvt` include it. This allows both typed and void events
to be mixed without the need for explicit `AnyEvent` superclasses.

---

### Step 2 — Use Macros for Unified Type Inference
Introduce a macro-based entry point for `choose` that generates appropriate code for the
number and kinds of arguments:

```crystal
macro choose(*evts)
  {% if evts.size < 2 %}
    {% raise "CML.choose requires at least two events" %}
  {% end %}

  {% types = evts.map { |e| e.resolve_type }
                  .map { |t| t.is_a?(Void) ? Nil : t } %}
  {% unified = types.reduce { |a, b| a.union(b) } %}

  CML.__choose_impl({{unified}}, [{{evts.splat}}])
end
```

Then, implement `__choose_impl` for uniform handling of polling and registration.
This eliminates all overload duplication and centralizes logic.

---

### Step 3 — Simplify `select` as `sync(choose(...))`
Once `choose` is macro-driven, we can make all `select` variants redirect to it:

```crystal
def self.select(*evts : EventLike) : _
  CML.sync(CML.choose(*evts))
end
```

This guarantees consistent typing and runtime semantics between the two forms.

---

### Step 4 — Type-Safe Guard and Timeout Integration
`GuardEvt` and `TimeoutEvt` will both unify as `Event(Symbol | Nil | T)`.
We’ll modify `GuardEvt` to infer its internal return type and store it in a type
parameter, not a hardcoded `Nil` default.

```crystal
class GuardEvt(T)
  def initialize(&@mk_evt : -> Event(T)); end
end
```

---

### Step 5 — Explicit `Void` as `Nil` Proxy
In Crystal, `Void` can be semantically represented by `Nil`. All control events
(`TimeoutEvt`, `NackEvt`, `NeverEvt(Void)`) will explicitly be `Event(Nil)`.
This simplifies array unification and matches how Crystal’s `nil` works naturally.

---

### Step 6 — Strengthen Validation
Add runtime validation:

```crystal
raise ArgumentError.new("choose requires ≥ 2 events") if evts.size < 2
```

and type-level assertions through specs ensuring proper unions are formed.

---

## Phased Implementation Plan

| Phase | Description | Milestone Output |
|-------|--------------|------------------|
| **1** | Define `EventLike` module, retrofit all event types to include it | ✅ Compiles |
| **2** | Add `choose` macro and `__choose_impl` helper | ✅ Handles unions dynamically |
| **3** | Replace overloads in `choose` and `select` | ✅ Cleaner API |
| **4** | Update specs: guard, nack, timeout, choose, select | ✅ All green |
| **5** | Benchmark regression to confirm zero overhead | ✅ Comparable to baseline |

---

## Test Coverage Matrix

| Test Category | Case | Expected Behavior |
|----------------|------|-------------------|
| **choose basic** | Two `always` events | First wins deterministically |
| **choose mixed** | `recv_evt` + `timeout` | Chooses whichever fires first |
| **guard** | Guarded timeout vs always | Guarded side-effect triggers only once |
| **nack** | Nack event cancellation | Cancellation callback runs once |
| **select macro** | 2+ heterogeneous events | Returns correct unified type |
| **never** | Never + always | Always wins |
| **with_timeout** | Wraps result in tagged tuple | `(:ok | :timeout)` variants |

---

## Validation Strategy

1. **Compilation validation** across all Crystal versions ≥ 1.12.
2. **Spec execution** for guard/nack/timeouts to ensure side effects and cancellations.
3. **Performance regression** using the `timer_wheel` benchmark (expected <1% overhead).
4. **Cross-event stress** with 1,000+ concurrent events for correctness and cancellation integrity.

---

## Expected Outcome

✅ No more overload explosions or type inference failures
✅ Simplified `choose` and `select` semantics
✅ Consistent CML behavior faithful to the SML model
✅ Cleaner code and easier spec maintenance

---

**Path:** `plans/fixes/cml_choose_unification_plan.md`

**Author:** Auto-generated by ChatGPT (GPT‑5) for Dominic (“dsisnero”)
**Date:** November 2025
