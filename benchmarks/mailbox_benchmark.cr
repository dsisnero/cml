# benchmarks/mailbox_benchmark.cr
# Benchmark comparing mailbox implementations

require "../src/cml"
require "../src/cml/mailbox"
require "../src/cml/mailbox_bounded"
require "../src/cml/mailbox_lockfree"

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
puts "Mailbox Implementation Benchmark"
puts "=" * 60
puts

# Test parameters
NUM_MESSAGES = 10_000
NUM_PRODUCERS = 4
NUM_CONSUMERS = 4
ITERATIONS = 5

puts "Parameters:"
puts "  Messages: #{NUM_MESSAGES}"
puts "  Producers: #{NUM_PRODUCERS}"
puts "  Consumers: #{NUM_CONSUMERS}"
puts "  Iterations: #{ITERATIONS}"
puts

# ============================================
# Benchmark 1: Single producer, single consumer throughput
# ============================================
puts "-" * 60
puts "Benchmark 1: Single producer, single consumer (#{NUM_MESSAGES} msgs)"
puts "-" * 60

# Basic mailbox
basic_spsc = benchmark("Basic Mailbox (mailbox.cr)", ITERATIONS) do
  mb = CML::Mailbox(Int32).new
  done = Channel(Nil).new

  spawn do
    NUM_MESSAGES.times do |i|
      mb.send(i)
    end
  end

  spawn do
    NUM_MESSAGES.times do
      CML.sync(mb.recv_evt)
    end
    done.send(nil)
  end

  done.receive
end

# Bounded mailbox
bounded_spsc = benchmark("Bounded Mailbox (mailbox_bounded.cr)", ITERATIONS) do
  mb = CML::MailboxBounded(Int32).new(capacity: 1000)
  done = Channel(Nil).new

  spawn do
    NUM_MESSAGES.times do |i|
      mb.send(i)
    end
  end

  spawn do
    NUM_MESSAGES.times do
      CML.sync(mb.recv_evt)
    end
    done.send(nil)
  end

  done.receive
end

# Lock-free mailbox
lockfree_spsc = benchmark("Lock-free Mailbox (mailbox_lockfree.cr)", ITERATIONS) do
  mb = CML::MailboxLockFree(Int32).new
  done = Channel(Nil).new

  spawn do
    NUM_MESSAGES.times do |i|
      mb.send(i)
    end
  end

  spawn do
    NUM_MESSAGES.times do
      CML.sync(mb.recv_evt)
    end
    done.send(nil)
  end

  done.receive
end

puts

# ============================================
# Benchmark 2: Multi-producer, multi-consumer
# ============================================
puts "-" * 60
puts "Benchmark 2: Multi-producer, multi-consumer (#{NUM_MESSAGES} msgs)"
puts "-" * 60

# Basic mailbox MPMC
basic_mpmc = benchmark("Basic Mailbox (mailbox.cr)", ITERATIONS) do
  mb = CML::Mailbox(Int32).new
  producer_done = Channel(Nil).new
  consumer_done = Channel(Nil).new
  msgs_per_producer = NUM_MESSAGES // NUM_PRODUCERS
  msgs_per_consumer = NUM_MESSAGES // NUM_CONSUMERS

  # Spawn producers
  NUM_PRODUCERS.times do |p|
    spawn do
      msgs_per_producer.times do |i|
        mb.send(p * msgs_per_producer + i)
      end
      producer_done.send(nil)
    end
  end

  # Spawn consumers
  NUM_CONSUMERS.times do
    spawn do
      msgs_per_consumer.times do
        CML.sync(mb.recv_evt)
      end
      consumer_done.send(nil)
    end
  end

  # Wait for all
  NUM_PRODUCERS.times { producer_done.receive }
  NUM_CONSUMERS.times { consumer_done.receive }
end

# Bounded mailbox MPMC
bounded_mpmc = benchmark("Bounded Mailbox (mailbox_bounded.cr)", ITERATIONS) do
  mb = CML::MailboxBounded(Int32).new(capacity: 1000)
  producer_done = Channel(Nil).new
  consumer_done = Channel(Nil).new
  msgs_per_producer = NUM_MESSAGES // NUM_PRODUCERS
  msgs_per_consumer = NUM_MESSAGES // NUM_CONSUMERS

  # Spawn producers
  NUM_PRODUCERS.times do |p|
    spawn do
      msgs_per_producer.times do |i|
        mb.send(p * msgs_per_producer + i)
      end
      producer_done.send(nil)
    end
  end

  # Spawn consumers
  NUM_CONSUMERS.times do
    spawn do
      msgs_per_consumer.times do
        CML.sync(mb.recv_evt)
      end
      consumer_done.send(nil)
    end
  end

  # Wait for all
  NUM_PRODUCERS.times { producer_done.receive }
  NUM_CONSUMERS.times { consumer_done.receive }
end

# Lock-free mailbox MPMC
lockfree_mpmc = benchmark("Lock-free Mailbox (mailbox_lockfree.cr)", ITERATIONS) do
  mb = CML::MailboxLockFree(Int32).new
  producer_done = Channel(Nil).new
  consumer_done = Channel(Nil).new
  msgs_per_producer = NUM_MESSAGES // NUM_PRODUCERS
  msgs_per_consumer = NUM_MESSAGES // NUM_CONSUMERS

  # Spawn producers
  NUM_PRODUCERS.times do |p|
    spawn do
      msgs_per_producer.times do |i|
        mb.send(p * msgs_per_producer + i)
      end
      producer_done.send(nil)
    end
  end

  # Spawn consumers
  NUM_CONSUMERS.times do
    spawn do
      msgs_per_consumer.times do
        CML.sync(mb.recv_evt)
      end
      consumer_done.send(nil)
    end
  end

  # Wait for all
  NUM_PRODUCERS.times { producer_done.receive }
  NUM_CONSUMERS.times { consumer_done.receive }
end

puts

# ============================================
# Benchmark 3: Event-based (recv_evt) vs non-blocking (recv_poll)
# ============================================
puts "-" * 60
puts "Benchmark 3: try_recv_now throughput (#{NUM_MESSAGES} msgs)"
puts "-" * 60

# Fill then drain with try_recv_now
basic_poll = benchmark("Basic Mailbox try_recv_now", ITERATIONS) do
  mb = CML::Mailbox(Int32).new

  # Fill
  NUM_MESSAGES.times do |i|
    mb.send(i)
  end

  # Drain with polling
  count = 0
  while (v = mb.try_recv_now) != nil
    count += 1
  end
end

bounded_poll = benchmark("Bounded Mailbox try_recv_now", ITERATIONS) do
  mb = CML::MailboxBounded(Int32).new(capacity: NUM_MESSAGES + 100)

  # Fill
  NUM_MESSAGES.times do |i|
    mb.send(i)
  end

  # Drain with polling
  count = 0
  while (v = mb.try_recv_now) != nil
    count += 1
  end
end

lockfree_poll = benchmark("Lock-free Mailbox try_recv_now", ITERATIONS) do
  mb = CML::MailboxLockFree(Int32).new

  # Fill
  NUM_MESSAGES.times do |i|
    mb.send(i)
  end

  # Drain with polling
  count = 0
  while (v = mb.try_recv_now) != nil
    count += 1
  end
end

puts

# ============================================
# Summary
# ============================================
puts "=" * 60
puts "Summary"
puts "=" * 60
puts
puts "SPSC throughput (lower is better):"
puts "  Basic:     #{basic_spsc.round(3)}ms"
puts "  Bounded:   #{bounded_spsc.round(3)}ms"
puts "  Lock-free: #{lockfree_spsc.round(3)}ms"
puts
puts "MPMC throughput (lower is better):"
puts "  Basic:     #{basic_mpmc.round(3)}ms"
puts "  Bounded:   #{bounded_mpmc.round(3)}ms"
puts "  Lock-free: #{lockfree_mpmc.round(3)}ms"
puts
puts "Polling throughput (lower is better):"
puts "  Basic:     #{basic_poll.round(3)}ms"
puts "  Bounded:   #{bounded_poll.round(3)}ms"
puts "  Lock-free: #{lockfree_poll.round(3)}ms"
puts
puts "=" * 60
puts "Recommendation based on SML/NJ compatibility:"
puts "  - mailbox.cr is closest to SML semantics (simple queue-based)"
puts "  - Lock-free/bounded are optimizations not in SML/NJ"
puts "  - For SML compatibility: use mailbox.cr"
puts "  - For high-throughput workloads: benchmarks above show best choice"
puts "=" * 60