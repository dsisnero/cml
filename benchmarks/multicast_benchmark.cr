# benchmarks/multicast_benchmark.cr
# Benchmark comparing multicast implementations

require "../src/cml"
require "../src/ivar"
require "../src/mvar"
require "../src/cml/mailbox"
require "../src/cml/multicast"
require "../src/cml/multicast_sml"
require "../src/cml/multicast_memory_efficient"

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
puts "Multicast Implementation Benchmark"
puts "=" * 60
puts

# Test parameters
NUM_MESSAGES    = 1_000
NUM_SUBSCRIBERS =     4
ITERATIONS      =     5

puts "Parameters:"
puts "  Messages: #{NUM_MESSAGES}"
puts "  Subscribers: #{NUM_SUBSCRIBERS}"
puts "  Iterations: #{ITERATIONS}"
puts

# ============================================
# Benchmark 1: Single message to multiple subscribers
# ============================================
puts "-" * 60
puts "Benchmark 1: Single message to #{NUM_SUBSCRIBERS} subscribers"
puts "-" * 60

# Simple multicast (server-based with Mailbox using MChan)
simple_sub = benchmark("Simple Multicast (multicast.cr)", ITERATIONS) do
  mc = CML::MChan(Int32).new
  done = Channel(Nil).new

  # Start subscribers
  ports = [] of CML::Port(Int32)
  NUM_SUBSCRIBERS.times do
    ports << mc.new_port
  end

  # Spawn receivers
  NUM_SUBSCRIBERS.times do |i|
    port = ports[i]
    spawn do
      NUM_MESSAGES.times do
        CML.sync(port.mailbox.recv_evt)
      end
      done.send(nil)
    end
  end

  # Let fibers start
  Fiber.yield

  # Send messages
  spawn do
    NUM_MESSAGES.times do |i|
      mc.multicast(i)
      Fiber.yield # Let receivers process
    end
  end

  # Wait for all receivers
  NUM_SUBSCRIBERS.times { done.receive }
end

# SML Multicast (IVar/MVar-based)
sml_sub = benchmark("SML Multicast (multicast_sml.cr)", ITERATIONS) do
  mc = CML::MulticastChan(Int32).new
  done = Channel(Nil).new

  # Start subscribers
  ports = [] of CML::MulticastPort(Int32)
  NUM_SUBSCRIBERS.times do
    ports << mc.port
  end

  # Spawn receivers
  NUM_SUBSCRIBERS.times do |i|
    port = ports[i]
    spawn do
      NUM_MESSAGES.times do
        CML.sync(port.recv_evt)
      end
      done.send(nil)
    end
  end

  # Let fibers start
  Fiber.yield

  # Send messages
  spawn do
    NUM_MESSAGES.times do |i|
      mc.multicast(i)
      Fiber.yield # Let receivers process
    end
  end

  # Wait for all receivers
  NUM_SUBSCRIBERS.times { done.receive }
end

# Memory-efficient multicast (lock-free)
mem_eff_sub = benchmark("Memory-Efficient (multicast_memory_efficient.cr)", ITERATIONS) do
  mc = CML::MChanMemoryEfficient(Int32).new
  done = Channel(Nil).new

  # Start subscribers
  ports = [] of CML::PortMemoryEfficient(Int32)
  NUM_SUBSCRIBERS.times do
    ports << mc.new_port
  end

  # Spawn receivers
  NUM_SUBSCRIBERS.times do |i|
    port = ports[i]
    spawn do
      NUM_MESSAGES.times do
        CML.sync(port.mailbox.recv_evt)
      end
      done.send(nil)
    end
  end

  # Let fibers start
  Fiber.yield

  # Send messages
  spawn do
    NUM_MESSAGES.times do |i|
      mc.multicast(i)
      Fiber.yield # Let receivers process
    end
  end

  # Wait for all receivers
  NUM_SUBSCRIBERS.times { done.receive }
end

puts

# ============================================
# Summary
# ============================================
puts "=" * 60
puts "Summary"
puts "=" * 60
puts
puts "Subscriber throughput (lower is better):"
puts "  Simple:           #{simple_sub.round(3)}ms"
puts "  SML (IVar/MVar):  #{sml_sub.round(3)}ms"
puts "  Memory-Efficient: #{mem_eff_sub.round(3)}ms"
puts
puts "=" * 60
puts "Recommendation based on SML/NJ compatibility:"
puts "  - multicast_sml.cr is the true SML port (IVar/MVar state cells)"
puts "  - multicast.cr is a simple server-based approach (not SML pattern)"
puts "  - multicast_memory_efficient.cr is a lock-free optimization (not SML)"
puts "  - For SML compatibility: use multicast_sml.cr"
puts "=" * 60
