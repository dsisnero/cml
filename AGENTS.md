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
## | `src/cml.cr` | Core implementation of CML runtime (Events, Pick, Chan, DSL helpers). |

---

## 6. Phase 5: Usability & DSL Helpers

Phase 5 introduces a usability layer to CML:

- Simple DSL helpers: `CML.after(span) { ... }`, `CML.spawn_evt { ... }`
- Example-driven cookbook: `docs/cookbook.md`
- Expanded examples: see `examples/` for chat, pipeline, and timeout worker demos
- Quickstart and helper docs in `README.md`
- Example-driven specs for helpers

AI agents should:

- Ensure all helpers are covered by specs
- Keep documentation and examples up to date
- Review API ergonomics for clarity and minimalism
| `src/trace_macro.cr` | Macro-based tracing system for CML events and fiber context. |

| `spec/cml2_spec.cr` | Basic behavior verification (choose, timeout, guard, nack). |
| `spec/smoke_test.cr` | Minimal smoke test verifying choose/timeout correctness. |
| `README.md` | Public overview of the CML runtime. |
## | `AGENTS.md` | This guidance document. |
---

## 5. Tracing and Instrumentation

CML provides a macro-based tracing system for debugging, performance analysis, and event visualization. Key features:

- **Zero-overhead when disabled**: Tracing code is compiled out unless `-Dtrace` is passed.
- **Event IDs**: Every event and pick is assigned a unique ID for correlation.
- **Fiber context**: Trace output includes the current fiber (or user-assigned fiber name).
- **Outcome tracing**: Commit/cancel outcomes are logged for all key CML operations.
- **User-defined tags**: `CML.trace` accepts an optional `tag:` argument for grouping/filtering.
- **Flexible output**: Trace output can be redirected to any IO (file, pipe, etc) via `CML::Tracer.set_output(io)`.
- **Filtering**: Tracer can filter by tag, event type, or fiber using `set_filter_tags`, `set_filter_events`, and `set_filter_fibers`.

**Example usage:**

```crystal
CML.trace "Chan.register_send", value, pick, tag: "chan"
CML::Tracer.set_output(File.open("trace.log", "w"))
CML::Tracer.set_filter_tags(["chan", "pick"])
```

See `src/trace_macro.cr` for implementation details and configuration API.

---

## 4. Event Model Recap

An **event** is a value representing a synchronization action.

```crystal
abstract class Event(T)
  abstract def try_register(pick : Pick(T)) : Proc(Nil)
end

## Issue Tracking

This project uses **bd (beads)** for issue tracking.
Run `bd prime` for workflow context, or install hooks (`bd hooks install`) for auto-injection.

**Quick reference:**
- `bd ready` - Find unblocked work
- `bd create "Title" --type task --priority 2` - Create issue
- `bd close <id>` - Complete work
- `bd sync` - Sync with git (run at session end)

For full workflow details: `bd prime`

## Issue Tracking with bd (beads)

**IMPORTANT**: This project uses **bd (beads)** for ALL issue tracking. Do NOT use markdown TODOs, task lists, or other tracking methods.

### Why bd?

- Dependency-aware: Track blockers and relationships between issues
- Git-friendly: Auto-syncs to JSONL for version control
- Agent-optimized: JSON output, ready work detection, discovered-from links
- Prevents duplicate tracking systems and confusion

### Quick Start

**Check for ready work:**
```

```bash
bd ready --json
```

**Create new issues:**

```bash
bd create "Issue title" -t bug|feature|task -p 0-4 --json
bd create "Issue title" -p 1 --deps discovered-from:bd-123 --json
bd create "Subtask" --parent <epic-id> --json  # Hierarchical subtask (gets ID like epic-id.1)
```

**Claim and update:**

```bash
bd update bd-42 --status in_progress --json
bd update bd-42 --priority 1 --json
```

**Complete work:**

```bash
bd close bd-42 --reason "Completed" --json
```

### Issue Types

- `bug` - Something broken
- `feature` - New functionality
- `task` - Work item (tests, docs, refactoring)
- `epic` - Large feature with subtasks
- `chore` - Maintenance (dependencies, tooling)

### Priorities

- `0` - Critical (security, data loss, broken builds)
- `1` - High (major features, important bugs)
- `2` - Medium (default, nice-to-have)
- `3` - Low (polish, optimization)
- `4` - Backlog (future ideas)

### Workflow for AI Agents

1. **Check ready work**: `bd ready` shows unblocked issues
2. **Claim your task**: `bd update <id> --status in_progress`
3. **Work on it**: Implement, test, document
4. **Discover new work?** Create linked issue:
   - `bd create "Found bug" -p 1 --deps discovered-from:<parent-id>`
5. **Complete**: `bd close <id> --reason "Done"`
6. **Commit together**: Always commit the `.beads/issues.jsonl` file together with the code changes so issue state stays in sync with code state

### Writing Self-Contained Issues

Issues must be fully self-contained - readable without any external context (plans, chat history, etc.). A future session should understand the issue completely from its description alone.

**Required elements:**

- **Summary**: What and why in 1-2 sentences
- **Files to modify**: Exact paths (with line numbers if relevant)
- **Implementation steps**: Numbered, specific actions
- **Example**: Show before → after transformation when applicable

**Optional but helpful:**

- Edge cases or gotchas to watch for
- Test references (point to test files or test_data examples)
- Dependencies on other issues

**Bad example:**

```text
Implement the refactoring from the plan
```

**Good example:**

```text
Add timeout parameter to fetchUser() in src/api/users.ts

1. Add optional timeout param (default 5000ms)
2. Pass to underlying fetch() call
3. Update tests in src/api/users.test.ts

Example: fetchUser(id) → fetchUser(id, { timeout: 3000 })
Depends on: bd-abc123 (fetch wrapper refactor)
```

### Dependencies: Think "Needs", Not "Before"

`bd dep add X Y` = "X needs Y" = Y blocks X

**TRAP**: Temporal words ("Phase 1", "before", "first") invert your thinking!

```text
WRONG: "Phase 1 before Phase 2" → bd dep add phase1 phase2
RIGHT: "Phase 2 needs Phase 1" → bd dep add phase2 phase1
```

**Verify**: `bd blocked` - tasks blocked by prerequisites, not dependents.

### Auto-Sync

bd automatically syncs with git:

- Exports to `.beads/issues.jsonl` after changes (5s debounce)
- Imports from JSONL when newer (e.g., after `git pull`)
- No manual export/import needed!

### GitHub Copilot Integration

If using GitHub Copilot, also create `.github/copilot-instructions.md` for automatic instruction loading.
Run `bd onboard` to get the content, or see step 2 of the onboard instructions.

### MCP Server (Recommended)

If using Claude or MCP-compatible clients, install the beads MCP server:

```bash
pip install beads-mcp
```

Add to MCP config (e.g., `~/.config/claude/config.json`):

```json
{
  "beads": {
    "command": "beads-mcp",
    "args": []
  }
}
```

Then use `mcp__beads__*` functions instead of CLI commands.

### Managing AI-Generated Planning Documents

AI assistants often create planning and design documents during development:

- PLAN.md, IMPLEMENTATION.md, ARCHITECTURE.md
- DESIGN.md, CODEBASE_SUMMARY.md, INTEGRATION_PLAN.md
- TESTING_GUIDE.md, TECHNICAL_DESIGN.md, and similar files

**Best Practice: Use a dedicated directory for these ephemeral files**

**Recommended approach:**

- Create a `history/` directory in the project root
- Store ALL AI-generated planning/design docs in `history/`
- Keep the repository root clean and focused on permanent project files
- Only access `history/` when explicitly asked to review past planning

**Example .gitignore entry (optional):**

```text
# AI planning documents (ephemeral)
history/
```

**Benefits:**

- ✅ Clean repository root
- ✅ Clear separation between ephemeral and permanent documentation
- ✅ Easy to exclude from version control if desired
- ✅ Preserves planning history for archeological research
- ✅ Reduces noise when browsing the project

### CLI Help

Run `bd <command> --help` to see all available flags for any command.
For example: `bd create --help` shows `--parent`, `--deps`, `--assignee`, etc.

## 7. Concurrent IO Limitations

**IMPORTANT**: Crystal's standard `IO` objects are **not thread-safe** for concurrent access from multiple threads.

### Current Status
- **Thread-safe CML operations**: All CML event state, atomic flags, and synchronization primitives are thread-safe
- **IO object limitation**: Crystal's `IO` class instances cannot be safely accessed concurrently from multiple threads
- **Stress tests disabled**: Thread safety stress tests are disabled in `spec/eventloop_compat_spec.cr:190-303` (wrapped in `{% if false %}`)

### Workarounds
1. **Single-threaded IO access**: Only access each `IO` object from one thread
2. **Channel-based serialization**: Use `Chan` to serialize IO operations to a dedicated fiber
3. **Documentation**: Always document this limitation when discussing Parallel contexts

### Future Considerations
- A `ThreadSafeIO` wrapper could be implemented with per-IO mutex synchronization
- Crystal's execution context system may evolve to address this limitation

### AI Agent Requirements
- **Never assume IO thread-safety**: Even with thread-safe CML primitives, underlying IO is not safe
- **Document the limitation**: Add warnings when showing examples with Parallel contexts
- **Keep tests disabled**: Thread safety stress tests should remain disabled until solution is implemented
- **Recommend serialization patterns**: Show channel-based serialization in examples

### Important Rules

- ✅ Use bd for ALL task tracking
- ✅ Always use `--json` flag for programmatic use
- ✅ Link discovered work with `discovered-from` dependencies
- ✅ Check `bd ready` before asking "what should I work on?"
- ✅ Store AI planning docs in `history/` directory
- ✅ Run `bd <cmd> --help` to discover available flags
- ❌ Do NOT create markdown TODO lists
- ❌ Do NOT use external issue trackers
- ❌ Do NOT duplicate tracking systems
- ❌ Do NOT clutter repo root with planning documents
