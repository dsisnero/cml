# Additional Review of `plans/refactor_review.md` and `src/`

Reviewed against the current tree on 2026-05-31.

This document only covers **additional** findings that were not already called
out clearly in [`plans/refactor_review.md`](/Volumes/extreme_ssd/repos/github.com/dsisnero/cml/plans/refactor_review.md), or that deserve a stronger conclusion after direct verification.

## New confirmed bugs

### 1. `Cleanup.clean_all` runs standard cleanup work twice

**Severity:** high  
**Files:** [`src/cml/cleanup.cr`](/Volumes/extreme_ssd/repos/github.com/dsisnero/cml/src/cml/cleanup.cr:219), [`src/cml/cleanup.cr`](/Volumes/extreme_ssd/repos/github.com/dsisnero/cml/src/cml/cleanup.cr:276)

This is a real logic bug.

- `register_standard_cleaners` installs `"Channels&Mailboxes"` and `"Servers"` hooks via `add_cleaner` at lines `219-221`.
- `clean_all` then calls `clean(time)` at line `277`, which iterates those hooks.
- After that, `clean_all` directly calls `clean_channels`, `start_servers`, or `shutdown_servers` again at lines `278-285`.

So the standard cleanup paths are executed twice per lifecycle transition.

This is not just theoretical. A direct runtime check showed a logged server init proc ran **twice** after one `Cleanup.clean_all(AtInit)` call.

Impact:

- server init/shutdown hooks can run twice
- channel/mailbox reset work can run twice
- tests can pass by accident because the duplicate path hides the asynchronous one

Recommended fix:

- choose one mechanism only
- either keep standard cleaners in the hook registry and make `clean_all` only call `clean(time)`
- or remove the standard hook registration and keep the explicit direct calls

The current hybrid design is wrong.

### 2. Cleanup hooks are asynchronous, so init/shutdown is not complete when `clean_all` returns

**Severity:** high  
**Files:** [`src/cml/cleanup.cr`](/Volumes/extreme_ssd/repos/github.com/dsisnero/cml/src/cml/cleanup.cr:81), [`src/cml/cleanup.cr`](/Volumes/extreme_ssd/repos/github.com/dsisnero/cml/src/cml/cleanup.cr:93), [`src/cml.cr`](/Volumes/extreme_ssd/repos/github.com/dsisnero/cml/src/cml.cr:1312)

This is a lifecycle-semantics bug.

- `Cleanup.clean` spawns each hook in its own fiber at lines `91-95`.
- `clean_all` returns immediately after scheduling those fibers.
- `CML.run` calls `Cleanup.clean_all(AtInit)` and then immediately enters the user block at lines `1316-1319`.
- `CML.shutdown` and the `ensure` path in `CML.run` do the same for shutdown.

That means user code can start running before init cleaners finish, and shutdown can return before shutdown cleaners finish.

This is also directly reproducible. A small runtime check showed:

- immediately after `Cleanup.clean_all(AtInit)`, a slow custom cleaner had **not** run yet
- after a short sleep, it had run

So the current API does not provide synchronous cleanup phases even though `run` and `shutdown` are written as if it does.

Impact:

- initialization races with user code
- shutdown ordering is unreliable
- failures in spawned cleaners are detached from the caller

Recommended fix:

- make `clean` synchronous, or
- split the API into explicit async/sync variants and have `run`/`shutdown` use the sync one

### 3. Trace event filtering is broken because the macro uses source stringification

**Severity:** medium  
**Files:** [`src/trace_macro.cr`](/Volumes/extreme_ssd/repos/github.com/dsisnero/cml/src/trace_macro.cr:101), [`src/trace_macro.cr`](/Volumes/extreme_ssd/repos/github.com/dsisnero/cml/src/trace_macro.cr:128)

This is a real tracing bug.

The macro expands:

```crystal
::CML::Tracer.trace_impl({{ event_type.stringify }}, ...)
```

`stringify` captures the **source text**, not the runtime string value.

Consequences:

- `CML.trace "foo"` passes `"foo"` including quotes as the event type
- `CML.trace some_var` passes `"some_var"`, not the value of `some_var`
- `set_filter_events(["foo"])` does **not** match `CML.trace "foo"`

This was verified directly:

- filtering on `["foo"]` produced no output
- filtering on `["\"foo\""]` did match

That behavior conflicts with the documented API in `README.md` and the tracing docs, which consistently present event names as ordinary strings like `"Chan.register_send"`.

Recommended fix:

- pass `event_type` as a value when it is already a string expression
- if macro support for identifiers is still desired, normalize to a real runtime string instead of using raw source text for filtering

Related test gap:

- `spec/trace_macro_spec.cr` only checks `contain("spec_event")`, which still passes when the output contains `"spec_event"` with quotes

### 4. `Thread::Prop` and `Thread::Flag` retain per-fiber state indefinitely

**Severity:** medium  
**Files:** [`src/cml/thread.cr`](/Volumes/extreme_ssd/repos/github.com/dsisnero/cml/src/cml/thread.cr:327), [`src/cml/thread.cr`](/Volumes/extreme_ssd/repos/github.com/dsisnero/cml/src/cml/thread.cr:373)

This is a real retention problem and likely a long-run memory leak.

- `Thread::Prop` stores values in `@values = {} of UInt64 => T`
- `Thread::Flag` stores values in `@values = {} of UInt64 => Bool`
- both key by `Fiber.current.object_id`
- neither type has automatic cleanup on fiber exit
- `Flag` does not even expose a `clear` API

For short-lived fibers, these maps grow monotonically unless user code explicitly clears `Prop`, and `Flag` entries cannot be removed at all.

Secondary risk:

- if object ids are ever reused after GC, a new fiber could observe stale per-fiber state

Recommended fix:

- add lifecycle cleanup tied to `Thread::Id.mark_exited`
- or rework storage so values are attached to live fiber identity rather than an unmanaged numeric key

## Additional refactor opportunities

### 5. `Cleanup` currently mixes two competing designs

**Files:** [`src/cml/cleanup.cr`](/Volumes/extreme_ssd/repos/github.com/dsisnero/cml/src/cml/cleanup.cr:63), [`src/cml/cleanup.cr`](/Volumes/extreme_ssd/repos/github.com/dsisnero/cml/src/cml/cleanup.cr:219), [`src/cml/cleanup.cr`](/Volumes/extreme_ssd/repos/github.com/dsisnero/cml/src/cml/cleanup.cr:276)

Beyond the concrete bugs above, `Cleanup` is carrying too many overlapping mechanisms:

- hook registry via `add_cleaner`
- standard cleaners registered at module load
- explicit direct cleanup in `clean_all`
- duplicate `log_channel` API shapes

This module would benefit from one simplified model:

- one registry
- one execution path
- one synchronous lifecycle contract

Right now the structure itself is what made the double-execution bug possible.

### 6. `spawn_evt` naming and docs are drifting from actual behavior

**Files:** [`src/cml.cr`](/Volumes/extreme_ssd/repos/github.com/dsisnero/cml/src/cml.cr:1443), [`spec/dsl_helper_spec.cr`](/Volumes/extreme_ssd/repos/github.com/dsisnero/cml/spec/dsl_helper_spec.cr:11), [`README.md`](/Volumes/extreme_ssd/repos/github.com/dsisnero/cml/README.md:109)

This is not a runtime bug in `src/`, but it is an API clarity problem.

- the source defines `spawn_evt` as `Event(Thread::Id)`
- the spec also expects a `Thread::Id`
- the README and cookbook describe it as returning the block's result

That mismatch will mislead users into writing the wrong code.

Recommended fix:

- either rename/document it clearly as “spawn and return thread id”
- or implement a separate helper that actually returns the block result as an event

### 7. Running-state semantics remain confusing

**Files:** [`src/cml.cr`](/Volumes/extreme_ssd/repos/github.com/dsisnero/cml/src/cml.cr:412), [`src/cml.cr`](/Volumes/extreme_ssd/repos/github.com/dsisnero/cml/src/cml.cr:1312), [`spec/running_spec.cr`](/Volumes/extreme_ssd/repos/github.com/dsisnero/cml/spec/running_spec.cr:4)

This is more of a refactor/API hygiene issue than a proven bug, but it is worth calling out.

- `@@is_running` starts `true` by default
- `CML.run` refuses to run when `running?` is true
- multiple specs must manually call `CML.set_running(false)` before using `CML.run`
- several runtime errors still say “call `CML.run` first”

The public model is unclear:

- either CML is meant to be usable without `run`
- or `run` is meant to be the real entrypoint

The code currently tries to support both stories and ends up with confusing semantics.

## Priority recommendation

### Fix first

1. Make cleanup phases single-path and synchronous.
2. Fix trace event filtering by removing `stringify` from the event-type data path.
3. Add cleanup for `Thread::Prop` / `Thread::Flag` per-fiber storage.

### Refactor next

4. Simplify `Cleanup` into one lifecycle mechanism.
5. Resolve the `spawn_evt` contract mismatch.
6. Clarify whether `CML.run` is optional compatibility scaffolding or the intended runtime entrypoint.
