# CML Benchmarking Guide

This guide explains how to run and interpret benchmarks for the Crystal Concurrent ML (CML) library.

## Overview

The CML benchmarking system provides comprehensive performance measurement tools to:

- **Measure latency** of individual operations (events, channels, choices)
- **Track throughput** (operations per second) under load
- **Monitor memory usage** and allocation patterns
- **Compare performance** against baselines to detect regressions
- **Test scaling** with different numbers of concurrent workers

## Current Benchmarking Status (Phase 2)

Based on the development plan in `plan.md`, we are currently in **Phase 2 - Performance and Efficiency**. The following benchmarking infrastructure has been established:

### ✅ Completed Benchmark Infrastructure

- **Basic benchmark runner** (`src/benchmark/runner.cr`) with latency and throughput measurement
- **Baseline management** (`src/benchmark/baseline_manager.cr`) for regression detection
- **Multiple benchmark suites** in the `benchmarks/` directory
- **Benchmark CLI** (`src/benchmark.cr`) for running and comparing benchmarks
- **Test coverage** for benchmark infrastructure (`spec/benchmark_runner_spec.cr`)

### 🎯 Phase 2 Targets Being Measured

- [ ] **Event creation and cancellation overhead** - measured in `benchmarks/cml_benchmarks.cr`
- [ ] **Heap allocations for short-lived events** - measured in `benchmarks/performance_benchmarks.cr`
- [ ] **Channel operation performance** - measured across multiple benchmark files
- [ ] **Worker scaling** with `CRYSTAL_WORKERS` > 1 - partially implemented
- [ ] **Microbenchmarks comparing to Go channels** - TODO

## Running Benchmarks

### Quick Start

```bash
# Run the simple benchmark suite
crystal run benchmarks/simple_bench.cr

# Run comprehensive CML benchmarks
crystal run benchmarks/cml_benchmarks.cr

# Run performance benchmarks with detailed metrics
crystal run benchmarks/performance_benchmarks.cr
```

### Using the Benchmark CLI

The main benchmark CLI provides more sophisticated benchmarking capabilities:

```bash
# Run all benchmarks
crystal run src/benchmark.cr -- run

# Save current results as baseline
crystal run src/benchmark.cr -- save-baseline my_test

# Compare current results with baseline
crystal run src/benchmark.cr -- compare-baseline my_test

# List available baselines
crystal run src/benchmark.cr -- list-baselines
```

### Advanced Benchmarking

For more detailed performance analysis:

```bash
# Run with different worker counts
CRYSTAL_WORKERS=4 crystal run benchmarks/cml_benchmarks.cr

# Run with memory profiling
crystal run --release --stats benchmarks/performance_benchmarks.cr

# Run specific benchmark sections
crystal eval 'require "./benchmarks/cml_benchmarks"; CML::Benchmarks.benchmark_channels'
```

## Benchmark Types

### 1. Latency Benchmarks

Measure the time taken for individual operations:

- **Event creation and synchronization** (`CML.always`, `CML.sync`)
- **Channel operations** (send/recv round trips)
- **Choice operations** with multiple alternatives
- **Combinator overhead** (`wrap`, `guard`, `nack`)

### 2. Throughput Benchmarks

Measure operations per second under sustained load:

- **High-frequency event processing**
- **Channel message passing rates**
- **Concurrent choice operations**

### 3. Memory Benchmarks

Track memory allocation patterns:

- **Heap allocations per operation**
- **GC pressure and frequency**
- **Memory growth under load**

### 4. Scaling Benchmarks

Test performance with different concurrency levels:

- **Single worker vs multiple workers**
- **Fiber count scaling**
- **Channel contention patterns**

## Interpreting Results

### Key Metrics

- **Mean latency**: Average operation time
- **P95/P99 latency**: Tail latency for worst-case performance
- **Throughput**: Operations per second
- **Memory allocations**: Bytes allocated per operation
- **GC impact**: Garbage collection frequency and duration

### Performance Targets

Based on Phase 2 goals:

- **Event overhead**: < 1μs per basic event operation
- **Channel round-trip**: < 10μs for send/recv pair
- **Memory efficiency**: Minimal allocations for common patterns
- **Scalability**: Linear or better scaling with worker count

### Regression Detection

The baseline system helps detect performance regressions:

```bash
# Save current performance as baseline
crystal run src/benchmark.cr -- save-baseline v0.1.0

# After changes, compare against baseline
crystal run src/benchmark.cr -- compare-baseline v0.1.0
```

Significant regressions (>10% performance degradation) should be investigated before merging changes.

## Benchmark Files Structure

```
benchmarks/
├── cml_benchmarks.cr          # Comprehensive CML operation benchmarks
├── performance_benchmarks.cr  # Detailed performance metrics
├── simple_bench.cr            # Quick verification benchmark
├── stress_test.cr             # High-load stress testing
└── baseline_suite.cr          # Baseline comparison suite

src/benchmark/
├── runner.cr                  # Core benchmark runner
├── baseline_manager.cr        # Baseline storage and comparison
├── cases.cr                   # Standard benchmark cases
└── benchmark.cr               # Main CLI interface
```

## Adding New Benchmarks

### 1. Create Benchmark Case

```crystal
# In benchmarks/my_benchmark.cr
require "benchmark"
require "../src/cml"

module CML::Benchmarks
  def self.benchmark_my_feature
    puts "=== My Feature Benchmark ==="

    Benchmark.ips do |x|
      x.report("my_operation") do
        # Your benchmark code here
        CML.sync(CML.always(42))
      end
    end
  end
end

# Run if executed directly
if PROGRAM_NAME == __FILE__
  CML::Benchmarks.benchmark_my_feature
end
```

### 2. Add to Benchmark Runner

Update `src/benchmark/cases.cr` to include your new benchmark:

```crystal
module CML::Benchmark
  class Cases
    def my_feature_benchmark
      # Implementation using Runner
    end
  end
end
```

### 3. Update CLI

Add your benchmark to the CLI in `src/benchmark.cr` if needed.

## Best Practices

### Benchmarking Guidelines

1. **Use release mode** for accurate performance measurements
2. **Warm up** the system before measuring
3. **Run multiple iterations** to get stable results
4. **Measure both latency and throughput**
5. **Test with realistic workloads**
6. **Compare against baselines** to detect regressions

### Performance Optimization Tips

When optimizing based on benchmark results:

- Focus on **hot paths** identified by profiling
- Reduce **heap allocations** in performance-critical code
- Use **atomic operations** and **Mutex** consistently
- Verify **non-blocking invariants** after optimization
- Test with **CRYSTAL_WORKERS > 1** for concurrency scaling

## Troubleshooting

### Common Issues

- **High variance in results**: Increase iteration count or use longer measurement periods
- **Memory leaks**: Check for proper event cleanup and cancellation
- **Performance regressions**: Use baseline comparison to identify when regressions occurred
- **Benchmark crashes**: Check for infinite loops or resource exhaustion

### Debugging Performance

```bash
# Run with debug output
DEBUG=1 crystal run benchmarks/cml_benchmarks.cr

# Profile memory usage
crystal run --release --stats benchmarks/performance_benchmarks.cr

# Check for memory leaks
valgrind --leak-check=full ./benchmarks/performance_benchmarks
```

## Next Steps

Based on Phase 2 goals, the following benchmarking improvements are planned:

- [ ] Add microbenchmarks comparing to Go channels
- [ ] Implement lock-free queue benchmarks for `Chan`
- [ ] Add pooling benchmarks for `Pick` objects
- [ ] Create stress tests with thousands of fibers
- [ ] Add property-based testing for correctness under load

## Contributing

When contributing performance improvements:

1. **Run benchmarks before and after** changes
2. **Document performance impact** in pull requests
3. **Add new benchmarks** for new features
4. **Update baselines** when performance characteristics change
5. **Follow the AI guidance** in `plan.md` for optimization safety

---

## Advanced Benchmark Harness Design

To ensure no performance degradation as the codebase evolves, consider these harness improvements:

- **Parameterized Runs**: Allow each scenario to accept parameters (e.g., fiber count, message size, event type).
- **CSV/JSON Output**: Support outputting results in machine-readable formats for easier comparison and plotting.
- **Scenario Tagging**: Tag scenarios by feature (e.g., `channel`, `timeout`, `choose`) to filter/select relevant tests.
- **Automated Baseline Comparison**: Integrate scripts to compare current results to saved baselines and highlight regressions.
- **Result Storage**: Store results in `benchmarks/results/` with filenames indicating branch, date, and scenario.

### Example: Saving and Comparing Results

```sh
# Save results for current branch
crystal run benchmarks/cml_benchmarks.cr --release > benchmarks/results/results-main-$(date +%Y%m%d).txt

# Save results for feature branch
crystal run benchmarks/cml_benchmarks.cr --release > benchmarks/results/results-feature-$(date +%Y%m%d).txt

# Compare results
colordiff -u benchmarks/results/results-main-20251027.txt benchmarks/results/results-feature-20251027.txt
```

### Checklist Before Merging Performance-Sensitive Changes

- [ ] Run all benchmarks in release mode
- [ ] Save results and compare to baseline/main
- [ ] Investigate any regressions >5%
- [ ] Document results in the pull request
- [ ] Add/expand scenarios for new features or code paths

---

*This guide is part of Phase 2 - Performance and Efficiency in the CML development plan.*