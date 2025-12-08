# CML Improvement Plan - Current Status

## Current Issue: CML.choose Macro Infinite Recursion

### Problem Analysis
- **Root Cause**: `__choose_from_array` method calls `choose(events)` which expands to call `__choose_from_array` again
- **Impact**: All specs using `CML.choose([...])` syntax fail to compile
- **Files Affected**:
  - `src/cml.cr` - `__choose_from_array` method implementation
  - Multiple spec files using array syntax

### Technical Details
- **Macro Expansion**: `CML.choose([evt1, evt2])` → `CML.__choose_from_array([evt1, evt2])`
- **Method Implementation**: `__choose_from_array` calls `choose(events)` → macro expansion → infinite recursion
- **Type System Issue**: Return type annotation `Event(T)` doesn't match actual return type

## Completed Workstreams

### Workstream A: Code Analysis & Documentation ✅
- ✅ Analyze all core files for code quality
- ✅ Improve documentation and comments
- ✅ Review architecture and design patterns

### Workstream B: Performance & Features ✅
- ✅ Timer wheel optimizations
- ✅ Lock-free mailbox variants
- ✅ MVar optimizations
- ✅ Object pooling
- ✅ Data structure optimizations
- ✅ Multicast channels
- ✅ Selective receive patterns
- ✅ Fiber scheduling optimizations
- ✅ Bounded mailboxes
- ✅ Performance counters
- ✅ Connection pooling
- ✅ Backpressure mechanisms
- ✅ Error handling strategy

## Current Workstream: Bug Fixes & Type System

### Workstream C: Critical Bug Fixes 🔄
- 🔄 **Task 1**: Fix CML.choose macro infinite recursion
  - Issue: `__choose_from_array` method creates infinite recursion
  - Solution: Implement proper delegation without macro expansion
  - Status: Investigating

- 🔄 **Task 2**: Resolve connection pool type unification
  - Issue: `available_evt` (Nil) vs `timeout_evt` (Symbol) type mismatch
  - Solution: Fix choose macro to properly handle heterogeneous types
  - Status: Blocked by Task 1

- 🔄 **Task 3**: Test and fix all specs using array syntax
  - Issue: Multiple specs fail due to choose macro bug
  - Solution: Run comprehensive spec testing after fixes
  - Status: Blocked by Task 1

## Next Steps

### Immediate (Current Session)
1. **Fix `__choose_from_array` method**
   - Remove recursive macro call
   - Implement direct event selection logic
   - Ensure proper type unification

2. **Test connection pool implementation**
   - Verify type unification works correctly
   - Ensure compilation succeeds
   - Run connection pool specs

3. **Run comprehensive spec suite**
   - Test all specs using CML.choose
   - Verify no regressions
   - Ensure all tests pass

### Short-term (Next Session)
1. **Phase 5: Usability & Examples**
   - Complete examples folder
   - Add cookbook with idioms
   - Improve API ergonomics

2. **Phase 6: Validation & Benchmarks**
   - Stress testing with thousands of fibers
   - Performance benchmarks
   - Comparison with other implementations

### Long-term
1. **Phase 7: Packaging & CI/CD**
   - GitHub Actions CI
   - Shard metadata
   - Release preparation

2. **Phase 8: Advanced Features**
   - Supervisors/Actors
   - Fair choose
   - Bounded channels
   - Selectable IO

## Technical Notes

### Type Unification Challenge
- `CML.choose` must handle heterogeneous event types
- Expected: `Event(Nil | Symbol)` from `Event(Nil)` and `Event(Symbol)`
- Current: Compiler fails to infer unified type

### Macro Implementation Issues
- Macro expansion creates circular dependencies
- Type annotations don't match actual return types
- Need to separate macro logic from runtime logic

### Testing Strategy
- Focus on fixing core choose functionality first
- Then test connection pool implementation
- Finally run comprehensive spec suite

## Success Criteria
- [ ] All specs pass with `crystal spec`
- [ ] Connection pool compiles and works correctly
- [ ] No infinite recursion in choose macro
- [ ] Proper type unification for heterogeneous events

---

*Last Updated: 2025-11-20*
*Current Focus: Fixing CML.choose macro infinite recursion*