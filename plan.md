# plan.md — AI Agent Development Plan for the Crystal CML Codebase

This document outlines the **current state**, **next development phases**, and **guidelines for AI agents** contributing to this repository.
It is meant to help LLMs (e.g. ChatGPT, Claude, Copilot) collaborate safely on an evolving **Concurrent ML runtime for Crystal**.

---

## 1. Current State (Phase 0 — Stable Core)

**Milestone: “Green CML”**

✅ Achieved:
- Core event system (`Event(T)` abstract class)
- `Pick(T)` atomic commit mechanism
- `Chan(T)` with non-blocking send/recv registration
- Event combinators:
  - `choose`
  - `wrap`
  - `guard`
  - `nack`
  - `timeout`
  - `always` / `never`
- Verified specs (`spec/cml2_spec.cr`, `spec/smoke_test.cr`)
- Non-recursive, allocation-safe design (all classes, no structs)
- Deterministic cancellation and fiber termination
- Cross-fiber correctness confirmed by output trace

**Summary:**
The runtime is now a small, composable, fully functional Concurrent ML kernel in Crystal — safe, deterministic, and ready for extension.

---

## 2. Phase 1 — Performance and Efficiency

🎯 Goal: Optimize internal fiber scheduling and minimize GC churn.

**Targets**
- [✅] **Efficient Timer Wheel:** Re-architected `TimerWheel` to be self-starting and thread-safe, using an adaptive sleep strategy to eliminate busy-waiting. This resolved a critical deadlock and improved timer efficiency.
- [✅] **`choose` Race Condition:** Implemented a `poll` mechanism to allow `ChooseEvt` to synchronously identify and select immediate winners (like `AlwaysEvt`, even when wrapped), fixing a race condition and ensuring deterministic behavior in nested choices.
- [ ] Benchmark event creation and cancellation overhead.
- [ ] Reduce heap allocations for short-lived events.
- [ ] Investigate pooling of `Pick` objects.
- [ ] Explore lock-free queues for `Chan`.
- [ ] Profile using `CRYSTAL_WORKERS` > 1 for concurrency scaling.
- [ ] Implement microbenchmarks comparing to Go channels.

**AI guidance**
- When rewriting critical paths, use **atomic operations** and **Mutex** consistently.
- Verify non-blocking invariants after optimization.
- Do not use unsafe pointer operations or FFI for “speed.”

---

## 3. Phase 2 — Documentation & Developer Clarity

🎯 Goal: Make the system easy to understand and extend by humans and AI agents.

**Tasks**
- [ ] Add `README.md` (for humans): overview, install, examples
- [ ] Add `docs/overview.md` (for developers): deep dive into event semantics
- [ ] Expand `spec/` suite with coverage for:
  - [✅] Nested `choose`
  - [✅] Re-entrant guards
  - [✅] Multiple concurrent channels
  - [✅] Timeout cancellation stress
- [ ] Annotate each event type with docstrings describing its atomicity and fiber behavior
- [ ] Add diagrams for `Pick`, `choose`, and `Chan` flow

**AI guidance**
AI agents should:
- Generate docs and examples in Markdown.
- Keep technical accuracy (avoid anthropomorphism).
- Never insert blocking examples.

---

## 4. Phase 3 — Extended CML Primitives

🎯 Goal: Reach parity with full Concurrent ML implementations.

**New features planned**
| Primitive | Purpose |
|------------|----------|
| `guard_evt` (already done) | Lazy construction |
| `wrap_evt` (done) | Post-commit mapping |
| `nack_evt` (done) | Cleanup on cancel |
| `choose_all` | Select *all* ready events |
| `wrap_abort` | Add explicit abort semantics |
| `select` macro | Syntactic sugar for `choose` |
| `with_timeout(evt, span)` | Convenience helper |

**AI guidance**
- Maintain `try_register` contract.
- Add tests for all new combinators.
- Ensure compatibility with `choose` and `sync`.

---

## 5. Phase 4 — Instrumentation & Tracing

🎯 Goal: Observe and debug event scheduling.

**Tasks**
- [ ] Add optional trace logs for event registration, decision, and cancellation.
- [ ] Provide `CML.debug = true` flag for verbose mode.
- [ ] Implement a lightweight `Tracer` that records event lifecycles.
- [ ] Offer pretty-print for event trees (`inspect`/`to_s`).

**AI guidance**
- Instrument through wrappers, not inside primitives.
- Logs should be fiber-safe and off by default.
- Use Crystal’s `Log` module, not `puts`.

---

## 6. Phase 5 — Usability Layer & Examples

🎯 Goal: Make it easy to use in small Crystal programs.

**Deliverables**
- [ ] `examples/` folder: chat demo, pipeline, timeout worker.
- [ ] Simple DSL helpers:
  - `CML.after(span) { ... }`
  - `CML.spawn_evt { ... }`
- [ ] Cookbook with idioms for concurrent coordination.

**AI guidance**
- Demonstrate idiomatic fiber usage.
- Each example should terminate cleanly.

---

## 7. Phase 6 — Validation and Benchmarks

🎯 Goal: Validate correctness and performance on real workloads.

**Tasks**
- [ ] Stress test with thousands of fibers.
- [ ] Add race detectors and property tests.
- [ ] Compare fairness and throughput with Go CML and OCaml CML implementations.

---

## 8. Phase 7 — Packaging and CI/CD

🎯 Goal: Prepare for open-source release.

**Tasks**
- [ ] Add `.github/workflows/ci.yml` for specs.
- [ ] Add shard metadata (`shard.yml`).
- [ ] Version bump and tag `v0.2.0`.
- [ ] Publish to `shards.info` under `cml.cr`.

**AI guidance**
- Keep builds deterministic.
- Run `crystal tool format` before commits.

---

## 9. Phase 8 — Advanced Ideas (Optional)

| Idea | Description |
|------|--------------|
| **Supervisors / Actors** | Build supervision trees using events. |
| **Fair choose** | Randomized or round-robin selection. |
| **Bounded Chan** | Backpressure via buffer limits. |
| **Selectable IO** | Integrate with sockets using event abstraction. |
| **Formal Model Check** | Validate “one commit” rule with property testing. |

AI agents can propose or implement these only after all prior phases are verified green.

---

## 10. Contribution Rules for AI Agents

1. **Do not** change event semantics without tests.
2. **Do not** introduce blocking inside `try_register`.
3. **Always** run `crystal spec` after changes.
4. **Document** every new event or combinator.
5. **Update** `AGENTS.md` and `plan.md` when completing a phase.
6. **Preserve deterministic behavior** in all examples.
7. **Avoid recursion in structs** — use `class` for any recursive type.

---

## 11. Phase Summary

| Phase | Title | Status |
|--------|--------|--------|
| 0 | Stable Core | ✅ complete |
| 1 | Performance | 🟡 in progress |
| 2 | Documentation | 🟡 in progress |
| 3 | Extended Primitives | 🔲 not started |
| 4 | Tracing | 🔲 not started |
| 5 | Usability & Examples | 🔲 not started |
| 6 | Validation | 🔲 not started |
| 7 | Packaging | 🔲 not started |
| 8 | Advanced Ideas | 🔲 optional |

---

## 12. Long-Term Vision

> Build a **reference-grade CML library for Crystal**
> — safe, minimal, composable, and educational.

This project aims to become the go-to example of *event-based concurrency done right* in a statically typed, fiber-based language.

When in doubt, remember:

> **One pick, one commit, zero blocking.**


---

## 3. Phase 2 — Performance and Efficiency

🎯 Goal: Optimize internal fiber scheduling and minimize GC churn.

**Targets**
- [ ] Benchmark event creation and cancellation overhead.
- [ ] Reduce heap allocations for short-lived events.
- [ ] Investigate pooling of `Pick` objects.
- [ ] Explore lock-free queues for `Chan`.
- [ ] Profile using `CRYSTAL_WORKERS` > 1 for concurrency scaling.
- [ ] Implement microbenchmarks comparing to Go channels.

**AI guidance**
- When rewriting critical paths, use **atomic operations** and **Mutex** consistently.
- Verify non-blocking invariants after optimization.
- Do not use unsafe pointer operations or FFI for “speed.”

---

## 4. Phase 3 — Extended CML Primitives

🎯 Goal: Reach parity with full Concurrent ML implementations.

**New features planned**
| Primitive | Purpose |
|------------|----------|
| `guard_evt` (already done) | Lazy construction |
| `wrap_evt` (done) | Post-commit mapping |
| `nack_evt` (done) | Cleanup on cancel |
| `choose_all` | Select *all* ready events |
| `wrap_abort` | Add explicit abort semantics |
| `select` macro | Syntactic sugar for `choose` |
| `with_timeout(evt, span)` | Convenience helper |

**AI guidance**
- Maintain `try_register` contract.
- Add tests for all new combinators.
- Ensure compatibility with `choose` and `sync`.

---

## 5. Phase 4 — Instrumentation & Tracing

🎯 Goal: Observe and debug event scheduling.

**Tasks**
- [ ] Add optional trace logs for event registration, decision, and cancellation.
- [ ] Provide `CML.debug = true` flag for verbose mode.
- [ ] Implement a lightweight `Tracer` that records event lifecycles.
- [ ] Offer pretty-print for event trees (`inspect`/`to_s`).

**AI guidance**
- Instrument through wrappers, not inside primitives.
- Logs should be fiber-safe and off by default.
- Use Crystal’s `Log` module, not `puts`.

---

## 6. Phase 5 — Usability Layer & Examples

🎯 Goal: Make it easy to use in small Crystal programs.

**Deliverables**
- [ ] `examples/` folder: chat demo, pipeline, timeout worker.
- [ ] Simple DSL helpers:
  - `CML.after(span) { ... }`
  - `CML.spawn_evt { ... }`
- [ ] Cookbook with idioms for concurrent coordination.

**AI guidance**
- Demonstrate idiomatic fiber usage.
- Each example should terminate cleanly.

---

## 7. Phase 6 — Validation and Benchmarks

🎯 Goal: Validate correctness and performance on real workloads.

**Tasks**
- [ ] Stress test with thousands of fibers.
- [ ] Add race detectors and property tests.
- [ ] Compare fairness and throughput with Go CML and OCaml CML implementations.

---

## 8. Phase 7 — Packaging and CI/CD

🎯 Goal: Prepare for open-source release.

**Tasks**
- [ ] Add `.github/workflows/ci.yml` for specs.
- [ ] Add shard metadata (`shard.yml`).
- [ ] Version bump and tag `v0.2.0`.
- [ ] Publish to `shards.info` under `cml.cr`.

**AI guidance**
- Keep builds deterministic.
- Run `crystal tool format` before commits.

---

## 9. Phase 8 — Advanced Ideas (Optional)

| Idea | Description |
|------|--------------|
| **Supervisors / Actors** | Build supervision trees using events. |
| **Fair choose** | Randomized or round-robin selection. |
| **Bounded Chan** | Backpressure via buffer limits. |
| **Selectable IO** | Integrate with sockets using event abstraction. |
| **Formal Model Check** | Validate “one commit” rule with property testing. |

AI agents can propose or implement these only after all prior phases are verified green.

---

## 10. Contribution Rules for AI Agents

1. **Do not** change event semantics without tests.
2. **Do not** introduce blocking inside `try_register`.
3. **Always** run `crystal spec` after changes.
4. **Document** every new event or combinator.
5. **Update** `AGENTS.md` and `plan.md` when completing a phase.
6. **Preserve deterministic behavior** in all examples.
7. **Avoid recursion in structs** — use `class` for any recursive type.

---

## 11. Phase Summary

| Phase | Title | Status |
|--------|--------|--------|
| 0 | Stable Core | ✅ complete |
| 1 | Documentation | 🟡 in progress |
| 2 | Performance | 🔲 not started |
| 3 | Extended Primitives | 🔲 not started |
| 4 | Tracing | 🔲 not started |
| 5 | Usability & Examples | 🔲 not started |
| 6 | Validation | 🔲 not started |
| 7 | Packaging | 🔲 not started |
| 8 | Advanced Ideas | 🔲 optional |

---

## 12. Long-Term Vision

> Build a **reference-grade CML library for Crystal**
> — safe, minimal, composable, and educational.

This project aims to become the go-to example of *event-based concurrency done right* in a statically typed, fiber-based language.

When in doubt, remember:

> **One pick, one commit, zero blocking.**