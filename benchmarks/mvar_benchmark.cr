# benchmarks/mvar_benchmark.cr
# Benchmark comparing MVar implementations

require "../src/cml"
require "../src/mvar"
require "../src/mvar_optimized"

# Benchmark helper
def benchmark(name : String, iterations : Int32, &block)
  # Warmup
  3.times { block.call }

  # Actual benchmark
  times = [] of Float64
  iterations.times do
    start = Time.monotonic
    block.call
    elapsed = (Time.monotonic - start).total_milliseconds
    times << elapsed
  end

  avg = times.sum / times.size
  min = times.min
  max = times.max

  puts "#{name}:"
  puts "  avg: #{avg.round(3)}ms, min: #{min.round(3)}ms, max: #{max.round(3)}ms"
  avg
end

puts "=" * 60
puts "MVar Implementation Benchmark"
puts "=" * 60
puts

# Test parameters
NUM_OPERATIONS = 10_000
ITERATIONS     =      5

puts "Parameters:"
puts "  Operations: #{NUM_OPERATIONS}"
puts "  Iterations: #{ITERATIONS}"
puts

# ============================================
# Benchmark 1: Single producer, single consumer (put/take)
# ============================================
puts "-" * 60
puts "Benchmark 1: Single producer/consumer put-take (#{NUM_OPERATIONS} ops)"
puts "-" * 60

# Standard MVar
standard_spsc = benchmark("Standard MVar (mvar.cr)", ITERATIONS) do
  mv = CML::MVar(Int32).new
  done = Channel(Nil).new

  spawn do
    NUM_OPERATIONS.times do |i|
      mv.put(i)
    end
  end

  spawn do
    NUM_OPERATIONS.times do
      mv.take
    end
    done.send(nil)
  end

  done.receive
end

# Optimized MVar
optimized_spsc = benchmark("Optimized MVar (mvar_optimized.cr)", ITERATIONS) do
  mv = CML::MVarOptimized(Int32).new
  done = Channel(Nil).new

  spawn do
    NUM_OPERATIONS.times do |i|
      mv.put(i)
    end
  end

  spawn do
    NUM_OPERATIONS.times do
      mv.take
    end
    done.send(nil)
  end

  done.receive
end

puts

# ============================================
# Benchmark 2: Multiple producers, multiple consumers
# ============================================
puts "-" * 60
puts "Benchmark 2: Multiple producers/consumers (#{NUM_OPERATIONS} ops)"
puts "-" * 60

NUM_PRODUCERS = 4
NUM_CONSUMERS = 4

# Standard MVar MPMC
standard_mpmc = benchmark("Standard MVar (mvar.cr)", ITERATIONS) do
  mv = CML::MVar(Int32).new
  producer_done = Channel(Nil).new
  consumer_done = Channel(Nil).new
  ops_per_producer = NUM_OPERATIONS // NUM_PRODUCERS
  ops_per_consumer = NUM_OPERATIONS // NUM_CONSUMERS

  NUM_PRODUCERS.times do |producer_index|
    spawn do
      ops_per_producer.times do |i|
        mv.put(producer_index * ops_per_producer + i)
      end
      producer_done.send(nil)
    end
  end

  NUM_CONSUMERS.times do
    spawn do
      ops_per_consumer.times do
        mv.take
      end
      consumer_done.send(nil)
    end
  end

  NUM_PRODUCERS.times { producer_done.receive }
  NUM_CONSUMERS.times { consumer_done.receive }
end

# Optimized MVar MPMC
optimized_mpmc = benchmark("Optimized MVar (mvar_optimized.cr)", ITERATIONS) do
  mv = CML::MVarOptimized(Int32).new
  producer_done = Channel(Nil).new
  consumer_done = Channel(Nil).new
  ops_per_producer = NUM_OPERATIONS // NUM_PRODUCERS
  ops_per_consumer = NUM_OPERATIONS // NUM_CONSUMERS

  NUM_PRODUCERS.times do |producer_index|
    spawn do
      ops_per_producer.times do |i|
        mv.put(producer_index * ops_per_producer + i)
      end
      producer_done.send(nil)
    end
  end

  NUM_CONSUMERS.times do
    spawn do
      ops_per_consumer.times do
        mv.take
      end
      consumer_done.send(nil)
    end
  end

  NUM_PRODUCERS.times { producer_done.receive }
  NUM_CONSUMERS.times { consumer_done.receive }
end

puts

# ============================================
# Benchmark 3: Read operations (non-destructive)
# ============================================
puts "-" * 60
puts "Benchmark 3: Read operations (#{NUM_OPERATIONS} ops)"
puts "-" * 60

# Standard MVar read
standard_read = benchmark("Standard MVar (mvar.cr)", ITERATIONS) do
  mv = CML::MVar(Int32).new(42)

  NUM_OPERATIONS.times do
    mv.get
  end
end

# Optimized MVar read
optimized_read = benchmark("Optimized MVar (mvar_optimized.cr)", ITERATIONS) do
  mv = CML::MVarOptimized(Int32).new(42)

  NUM_OPERATIONS.times do
    mv.read
  end
end

puts

# ============================================
# Benchmark 4: Swap operations
# ============================================
puts "-" * 60
puts "Benchmark 4: Swap operations (#{NUM_OPERATIONS} ops)"
puts "-" * 60

# Standard MVar swap
standard_swap = benchmark("Standard MVar (mvar.cr)", ITERATIONS) do
  mv = CML::MVar(Int32).new(0)

  NUM_OPERATIONS.times do |i|
    mv.swap(i)
  end
end

# Note: MVarOptimized doesn't have a swap method
puts "Optimized MVar: N/A (no swap method)"
_ = Float64::MAX

puts

# ============================================
# Benchmark 5: CML Event-based operations
# ============================================
puts "-" * 60
puts "Benchmark 5: CML Event-based take (#{NUM_OPERATIONS} ops)"
puts "-" * 60

# Standard MVar event-based
standard_evt = benchmark("Standard MVar m_take_evt", ITERATIONS) do
  mv = CML::MVar(Int32).new
  done = Channel(Nil).new

  spawn do
    NUM_OPERATIONS.times do |i|
      mv.put(i)
    end
  end

  spawn do
    NUM_OPERATIONS.times do
      CML.sync(mv.m_take_evt)
    end
    done.send(nil)
  end

  done.receive
end

# MVarOptimized doesn't support CML events
puts "Optimized MVar: N/A (no CML event support)"
_ = Float64::MAX

puts

# ============================================
# Summary
# ============================================
puts "=" * 60
puts "Summary"
puts "=" * 60
puts
puts "SPSC put/take throughput (lower is better):"
puts "  Standard:  #{standard_spsc.round(3)}ms"
puts "  Optimized: #{optimized_spsc.round(3)}ms"
puts
puts "MPMC put/take throughput (lower is better):"
puts "  Standard:  #{standard_mpmc.round(3)}ms"
puts "  Optimized: #{optimized_mpmc.round(3)}ms"
puts
puts "Read throughput (lower is better):"
puts "  Standard:  #{standard_read.round(3)}ms"
puts "  Optimized: #{optimized_read.round(3)}ms"
puts
puts "Swap throughput (lower is better):"
puts "  Standard:  #{standard_swap.round(3)}ms"
puts "  Optimized: N/A (missing)"
puts
puts "CML Event throughput (lower is better):"
puts "  Standard:  #{standard_evt.round(3)}ms"
puts "  Optimized: N/A (missing)"
puts
puts "=" * 60
puts "Feature Comparison:"
puts "=" * 60
puts "| Feature              | Standard | Optimized |"
puts "|----------------------|----------|-----------|"
puts "| SML API (mPut, etc.) | ✓        | ✗         |"
puts "| CML Events           | ✓        | ✗         |"
puts "| swap/m_swap          | ✓        | ✗         |"
puts "| Pattern detection    | ✗        | ✓         |"
puts "| Concurrent safety    | ✓        | ✓         |"
puts
puts "=" * 60
puts "Recommendation:"
puts "  - Standard MVar (mvar.cr) is the ONLY choice for CML compatibility"
puts "  - Optimized MVar is incomplete and missing critical CML features"
puts "  - Standard MVar is required for SML/NJ compatibility"
puts "=" * 60
