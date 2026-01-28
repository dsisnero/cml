# Crystal 1.19 Concurrency Features Integration Plan

## Overview
Crystal 1.19 introduces several important concurrency-related features that could benefit the CML implementation. This document outlines a plan to integrate these features while maintaining compatibility and performance.

## New Features Analysis

### 1. Time::Instant (RFC 0015)
- **Current**: `Time.monotonic` returns `Time::Span` (deprecated in 1.19)
- **New**: `Time::Instant` represents monotonic timeline points
- **Impact**: Timer wheel, timeout events, and any timing measurements

### 2. Execution Contexts (Preview with `-Dpreview_mt -Dexecution_context`)
- Thread safety improvements in stdlib
- New synchronization primitives: `Sync::Mutex`, `Sync::RWLock`, `Sync::ConditionVariable`, `Sync::Exclusive`, `Sync::Shared`
- **Impact**: Potential need for thread-safe synchronization when CML runs with multiple OS threads

### 3. Process Improvements
- Better subprocess spawning with `posix_spawn`
- **Impact**: `CML::Process` module if using system commands

### 4. Compiler Changes
- LLVM codegen always multithreaded (performance improvement)
- **Impact**: Build performance, no code changes needed

## Current CML Implementation Assessment

### Thread Safety Assumptions
- CML currently assumes single-threaded fiber cooperative scheduling
- Uses standard `Mutex`, `Atomic`, `Deque` with mutex protection
- All synchronization is fiber-aware (uses `Fiber.suspend`/`Fiber.enqueue`)

### Timing Usage
1. `timer_wheel.cr` line 319: `Time.monotonic.total_milliseconds`
2. `AtTimeEvent` uses `Time.utc` for absolute time
3. `TimeoutEvent` uses `Time::Span` and timer wheel

### Synchronization Primitives Usage
- 35 instances of `Mutex.new` across the codebase
- Used for protecting queues, maps, and shared state
- All mutexes are standard Crystal `Mutex`

## Integration Strategy

### Phase 1: Time::Instant Migration (Non-breaking)

#### 1.1 Update TimerWheel
- Replace `Time.monotonic` with `Time.instant`
- Convert `Time::Instant` to milliseconds for tick calculations
- Maintain internal tick-based representation for efficiency

**Files**:
- `src/timer_wheel.cr:319`
- Update `process_expired_internal` method

**Example**:
```crystal
# Before
now_ms = Time.monotonic.total_milliseconds.to_u64

# After
now_ms = Time.instant.to_unix_ms.to_u64  # or custom conversion
```

#### 1.2 Create Time Conversion Helpers
Add helper methods in `CML` module for consistent time handling:

```crystal
module CML
  private def self.monotonic_milliseconds : UInt64
    {% if compare_versions(Crystal::VERSION, "1.19.0") >= 0 %}
      Time.instant.to_unix_ms.to_u64
    {% else %}
      Time.monotonic.total_milliseconds.to_u64
    {% end %}
  end
end
```

#### 1.3 Update AtTimeEvent
- Keep using `Time.utc` for absolute wall-clock time
- Consider adding `at_instant` variant for monotonic timing

#### 1.4 Update Documentation
- Note `Time.monotonic` deprecation
- Recommend `Time.instant` for new code

### Phase 2: Execution Contexts Preparation

#### 2.1 Conditional Synchronization Primitive Wrapper
Create a wrapper module that selects appropriate mutex based on compilation flags:

```crystal
module CML
  module Sync
    # Select mutex type based on compilation flags
    {% if flag?(:preview_mt) && flag?(:execution_context) %}
      alias Mutex = ::Sync::Mutex
    {% else %}
      alias Mutex = ::Mutex
    {% end %}

    # Similar for RWLock, ConditionVariable if needed
  end
end
```

#### 2.2 Audit Thread-Sensitive Code
Identify code that assumes single-threaded execution:
- `Thread::Id` registry uses global hash with mutex (already thread-safe)
- `Chan` queues with mutex (already thread-safe)
- `TransactionId` atomic operations (thread-safe)

#### 2.3 Fiber Safety in Multi-Threaded Context
- Verify `Fiber.current` uniqueness across threads
- Ensure `Fiber.suspend`/`Fiber.enqueue` work with execution contexts
- Test with `-Dpreview_mt -Dexecution_context`

### Phase 3: Sync Primitive Integration

#### 3.1 Gradual Migration Path
Option A: Direct replacement of `Mutex` with `CML::Sync::Mutex`
Option B: Configuration flag to enable `Sync::Mutex`

**Recommended**: Start with conditional compilation, measure performance impact.

#### 3.2 Update Key Components
1. `Chan` mutex protection
2. `TimerWheel` mutex
3. `Thread::Id` registry mutex
4. `TraceMacro` mutex

#### 3.3 Performance Testing
- Benchmark before/after changes
- Compare single-threaded vs multi-threaded scenarios

### Phase 4: Process Module Updates

#### 4.1 Review `CML::Process` Usage
- Currently uses `spawn` for subprocesses
- May benefit from new `Process.run` improvements

#### 4.2 Update if Needed
Minimal changes expected.

## Implementation Steps

### Step 1: Create Time Compatibility Layer
1. Add `cml/time_compat.cr` with version-aware helpers
2. Update timer_wheel.cr to use new helpers
3. Run existing tests

### Step 2: Update TimerWheel Implementation
1. Modify `process_expired_internal` method
2. Add conversion from `Time::Instant` to ticks
3. Verify timer accuracy

### Step 3: Add Sync Wrapper Module
1. Create `src/cml/sync.cr` with conditional aliases
2. Update AGENTS.md with new conventions
3. Document when to use `CML::Sync::Mutex` vs `::Mutex`

### Step 4: Pilot Sync Mutex in One Component
1. Update `Chan` mutex to use `CML::Sync::Mutex`
2. Run comprehensive tests
3. Benchmark channel performance

### Step 5: Gradual Rollout
1. Update remaining mutexes systematically
2. Each change accompanied by tests
3. Monitor for regressions

### Step 6: Multi-Threaded Testing
1. Create test suite with `-Dpreview_mt -Dexecution_context`
2. Test fiber migration across threads
3. Verify CML semantics preserved

## Testing Strategy

### Unit Tests
- All existing tests must pass
- Add version-specific tests for time compatibility
- Test both mutex implementations

### Integration Tests
- Test with `-Dpreview_mt -Dexecution_context` flag
- Test timer accuracy with `Time::Instant`
- Test channel operations across threads

### Performance Tests
- Benchmark critical paths before/after
- Compare `Mutex` vs `Sync::Mutex` overhead
- Measure timer precision

## Risks and Mitigations

### Risk 1: Performance Regression
- **Mitigation**: Benchmark each change, provide fallback to standard `Mutex`

### Risk 2: Breaking Changes
- **Mitigation**: Use version checks, maintain backward compatibility
- **Mitigation**: Keep changes behind feature flags initially

### Risk 3: Execution Contexts Unstable
- **Mitigation**: Treat as optional enhancement, not required
- **Mitigation**: Wait for Crystal 1.20 when enabled by default

## Success Criteria

1. All existing tests pass with Crystal 1.19+
2. No deprecation warnings for `Time.monotonic`
3. Optional support for `Sync::Mutex` when flags enabled
4. Thread-safe operation with execution contexts
5. Performance within 5% of original

## Timeline

- **Week 1**: Time::Instant migration
- **Week 2**: Sync wrapper and pilot
- **Week 3**: Gradual rollout and testing
- **Week 4**: Multi-threaded validation

## Files to Modify

### Primary
- `src/timer_wheel.cr`
- `src/cml.cr` (TimeoutEvent, AtTimeEvent)
- New: `src/cml/time_compat.cr`
- New: `src/cml/sync.cr`

### Secondary
- `src/cml/chan.cr` (if separate file)
- `src/cml/thread.cr`
- `src/trace_macro.cr`
- Various other mutex users

### Documentation
- `README.md` - note Crystal 1.19+ compatibility
- `AGENTS.md` - update coding conventions
- `docs/cookbook.md` - update timing examples

## References

1. Crystal 1.19.0 Release Notes: https://crystal-lang.org/2026/01/15/1.19.0-released/
2. RFC 0015: Time monotonic
3. RFC 0002: Execution contexts
4. Sync primitives API: https://crystal-lang.org/api/1.19.0/Sync.html

## Issue Tracking

- Created bd issue: `cml-ne4` - Integrate Crystal 1.19 concurrency features
- Link related issues as discovered