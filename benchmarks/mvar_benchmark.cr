# benchmarks/mvar_benchmark.cr
# MVar performance benchmarks (standard implementation only)

require "../src/cml"
require "../src/cml/mvar"

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
puts "MVar Benchmark"
puts "=" * 60
puts

NUM_OPERATIONS = 10_000
ITERATIONS     =      5

puts "Parameters:"
puts "  Operations: #{NUM_OPERATIONS}"
puts "  Iterations: #{ITERATIONS}"
puts

# -------------------------------------------
# Benchmark 1: SPSC put/take
# -------------------------------------------
puts "-" * 60
puts "Benchmark 1: Single producer/consumer put-take (#{NUM_OPERATIONS} ops)"
puts "-" * 60

spsc = benchmark("SPSC put/take", ITERATIONS) do
  mv = CML::MVar(Int32).new
  done = Channel(Nil).new
  spawn do
    NUM_OPERATIONS.times do |i|
      mv.m_put(i)
    end
  end
  spawn do
    NUM_OPERATIONS.times { mv.m_take }
    done.send(nil)
  end
  done.receive
end

puts

# -------------------------------------------
# Benchmark 2: MPMC put/take
# -------------------------------------------
puts "-" * 60
puts "Benchmark 2: Multiple producers/consumers (#{NUM_OPERATIONS} ops)"
puts "-" * 60

NUM_PRODUCERS = 4
NUM_CONSUMERS = 4

mpmc = benchmark("MPMC put/take", ITERATIONS) do
  mv = CML::MVar(Int32).new
  producer_done = Channel(Nil).new
  consumer_done = Channel(Nil).new
  ops_per_producer = NUM_OPERATIONS // NUM_PRODUCERS
  ops_per_consumer = NUM_OPERATIONS // NUM_CONSUMERS
  NUM_PRODUCERS.times do |pi|
    spawn do
      ops_per_producer.times do |i|
        mv.m_put(pi * ops_per_producer + i)
      end
      producer_done.send(nil)
    end
  end
  NUM_CONSUMERS.times do
    spawn do
      ops_per_consumer.times { mv.m_take }
      consumer_done.send(nil)
    end
  end
  NUM_PRODUCERS.times { producer_done.receive }
  NUM_CONSUMERS.times { consumer_done.receive }
end

puts

# -------------------------------------------
# Benchmark 3: Read operations (m_get, non-destructive)
# -------------------------------------------
puts "-" * 60
puts "Benchmark 3: Read operations (#{NUM_OPERATIONS} ops)"
puts "-" * 60

read_ops = benchmark("m_get (non-destructive read)", ITERATIONS) do
  mv = CML::MVar(Int32).new(42)
  NUM_OPERATIONS.times { mv.m_get }
end

puts

# -------------------------------------------
# Benchmark 4: Swap operations
# -------------------------------------------
puts "-" * 60
puts "Benchmark 4: Swap operations (#{NUM_OPERATIONS} ops)"
puts "-" * 60

swap_ops = benchmark("m_swap", ITERATIONS) do
  mv = CML::MVar(Int32).new(0)
  NUM_OPERATIONS.times do |i|
    mv.m_swap(i)
  end
end

puts

# -------------------------------------------
# Benchmark 5: CML Event-based take
# -------------------------------------------
puts "-" * 60
puts "Benchmark 5: CML Event-based take (#{NUM_OPERATIONS} ops)"
puts "-" * 60

event_take = benchmark("m_take_evt (CML event)", ITERATIONS) do
  mv = CML::MVar(Int32).new
  done = Channel(Nil).new
  spawn do
    NUM_OPERATIONS.times do |i|
      mv.m_put(i)
    end
  end
  spawn do
    NUM_OPERATIONS.times { CML.sync(mv.m_take_evt) }
    done.send(nil)
  end
  done.receive
end

puts

# -------------------------------------------
# Summary
# -------------------------------------------
puts "=" * 60
puts "Summary"
puts "=" * 60
puts "SPSC put/take:   #{spsc.round(3)}ms"
puts "MPMC put/take:   #{mpmc.round(3)}ms"
puts "m_get (read):    #{read_ops.round(3)}ms"
puts "m_swap:          #{swap_ops.round(3)}ms"
puts "m_take_evt:      #{event_take.round(3)}ms"
puts "=" * 60
