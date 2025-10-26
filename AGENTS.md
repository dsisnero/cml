# AGENTS.md — Guidance for AI Agents Working on the Crystal CML Codebase

This document provides context, policies, and implementation expectations for AI assistants contributing to this repository.
It is modeled after **CLAUDE.md** but designed to guide any AI code agent (ChatGPT, Claude, Copilot, etc.) when generating, refactoring, or extending this **Crystal Concurrent ML (CML)** implementation.

---

## 1. Repository Purpose

This repository implements a **Concurrent ML (CML)** runtime in **Crystal** — a small, correct, composable concurrency substrate.

It provides:
- First-class **events** (`Event(T)`) for synchronization.
- A **rendezvous channel** abstraction (`Chan(T)`).
- Core combinators: `choose`, `wrap`, `guard`, `nack`, `timeout`, and `sync`.
- Proper **cancellation and commit semantics** via atomic `Pick`.

This runtime is a foundation for testing concurrent design patterns, not a high-level framework.
AI assistants must preserve **determinism**, **non-blocking registration**, and **clarity of fiber control** at all times.

---

## 2. AI Agent Goals

When editing or generating code in this repository, AI assistants should:

1. **Preserve semantics**
   - Never introduce blocking behavior inside event registration.
   - Only `CML.sync(evt)` should block a fiber.
   - Maintain CML’s “one commit” invariant: exactly one event per choice succeeds.

2. **Maintain SOLID structure**
   - Keep `Pick`, `Event`, and `Chan` cleanly separated.
   - Avoid coupling between event primitives.
   - Use simple Crystal idioms — no macros unless necessary.

3. **Stay minimal and composable**
   - Avoid unnecessary abstractions or DSLs.
   - No dependencies beyond the Crystal standard library.

4. **Preserve fiber safety**
   - Always spawn cancellation fibers safely.
   - Avoid races on shared queues (use `@mtx.synchronize`).
   - Don’t assume preemption — Crystal fibers are cooperative.

5. **Keep deterministic tests**
   - Avoid random sleeps or timing hacks in specs.
   - Use timeouts as explicit events, not arbitrary delays.

---

## 3. Code Structure Overview

| File | Description |
|------|--------------|
| `src/cml.cr` | Core implementation of CML runtime (Events, Pick, Chan). |
| `spec/cml2_spec.cr` | Basic behavior verification (choose, timeout, guard, nack). |
| `spec/smoke_test.cr` | Minimal smoke test verifying choose/timeout correctness. |
| `README.md` | Public overview of the CML runtime. |
| `AGENTS.md` | This guidance document. |

---

## 4. Event Model Recap

An **event** is a value representing a synchronization action.

```crystal
abstract class Event(T)
  abstract def try_register(pick : Pick(T)) : Proc(Nil)
end