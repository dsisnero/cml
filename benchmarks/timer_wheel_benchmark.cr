# benchmarks/timer_wheel_benchmark.cr
# Benchmark comparing TimerWheel implementations

require "../src/timer_wheel"
require "../src/timer_wheel_optimized"

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
puts "TimerWheel Implementation Benchmark"
puts "=" * 60
puts

ITERATIONS = 5

# ============================================
# Benchmark 1: Schedule many short timers
# ============================================
puts "-" * 60
puts "Benchmark 1: Schedule 10000 short timers (10-100ms)"
puts "-" * 60

NUM_TIMERS = 10_000

# Standard TimerWheel
standard_short = benchmark("Standard TimerWheel", ITERATIONS) do
  tw = CML::TimerWheel.new(auto_advance: false, sync_callbacks: true)

  NUM_TIMERS.times do |i|
    duration = (10 + (i % 90)).milliseconds
    tw.schedule(duration) { }
  end

  tw.stop
end

# Optimized TimerWheel
optimized_short = benchmark("Optimized TimerWheel", ITERATIONS) do
  tw = CML::TimerWheelOptimized.new

  NUM_TIMERS.times do |i|
    duration = (10 + (i % 90)).milliseconds
    tw.schedule(duration) { }
  end

  tw.stop rescue nil
end

puts

# ============================================
# Benchmark 2: Schedule mixed duration timers
# ============================================
puts "-" * 60
puts "Benchmark 2: Schedule 10000 mixed duration timers (1ms-10s)"
puts "-" * 60

# Standard TimerWheel
standard_mixed = benchmark("Standard TimerWheel", ITERATIONS) do
  tw = CML::TimerWheel.new(auto_advance: false, sync_callbacks: true)

  NUM_TIMERS.times do |i|
    duration = case i % 4
               when 0 then (1 + i % 10).milliseconds    # 1-10ms
               when 1 then (100 + i % 900).milliseconds # 100-999ms
               when 2 then (1 + i % 5).seconds          # 1-5s
               else        (5 + i % 5).seconds          # 5-10s
               end
    tw.schedule(duration) { }
  end

  tw.stop
end

# Optimized TimerWheel
optimized_mixed = benchmark("Optimized TimerWheel", ITERATIONS) do
  tw = CML::TimerWheelOptimized.new

  NUM_TIMERS.times do |i|
    duration = case i % 4
               when 0 then (1 + i % 10).milliseconds    # 1-10ms
               when 1 then (100 + i % 900).milliseconds # 100-999ms
               when 2 then (1 + i % 5).seconds          # 1-5s
               else        (5 + i % 5).seconds          # 5-10s
               end
    tw.schedule(duration) { }
  end

  tw.stop rescue nil
end

puts

# ============================================
# Benchmark 3: Schedule and cancel timers
# ============================================
puts "-" * 60
puts "Benchmark 3: Schedule and cancel 5000 timers"
puts "-" * 60

# Standard TimerWheel
standard_cancel = benchmark("Standard TimerWheel", ITERATIONS) do
  tw = CML::TimerWheel.new(auto_advance: false, sync_callbacks: true)
  ids = [] of UInt64

  5000.times do |i|
    id = tw.schedule((100 + i).milliseconds) { }
    ids << id
  end

  ids.each do |id|
    tw.cancel(id)
  end

  tw.stop
end

# Optimized TimerWheel
optimized_cancel = benchmark("Optimized TimerWheel", ITERATIONS) do
  tw = CML::TimerWheelOptimized.new
  ids = [] of UInt64

  5000.times do |i|
    id = tw.schedule((100 + i).milliseconds) { }
    ids << id
  end

  ids.each do |id|
    tw.cancel(id)
  end

  tw.stop rescue nil
end

puts

# ============================================
# Benchmark 4: Timer execution (advance time)
# ============================================
puts "-" * 60
puts "Benchmark 4: Execute 1000 timers via advance"
puts "-" * 60

# Standard TimerWheel
standard_exec = benchmark("Standard TimerWheel", ITERATIONS) do
  tw = CML::TimerWheel.new(auto_advance: false, sync_callbacks: true)
  executed = 0

  1000.times do |i|
    tw.schedule((1 + i % 100).milliseconds) { executed += 1 }
  end

  # Advance time to execute all timers
  tw.advance(200.milliseconds)

  tw.stop
end

# Optimized doesn't have advance method
puts "Optimized TimerWheel: N/A (no advance method for testing)"

puts

# ============================================
# Benchmark 5: Interval timers
# ============================================
puts "-" * 60
puts "Benchmark 5: Schedule 1000 interval timers"
puts "-" * 60

# Standard TimerWheel
standard_interval = benchmark("Standard TimerWheel", ITERATIONS) do
  tw = CML::TimerWheel.new(auto_advance: false, sync_callbacks: true)

  1000.times do |i|
    tw.schedule_interval((10 + i % 90).milliseconds) { }
  end

  tw.stop
end

# Optimized TimerWheel
optimized_interval = benchmark("Optimized TimerWheel", ITERATIONS) do
  tw = CML::TimerWheelOptimized.new

  1000.times do |i|
    tw.schedule_interval((10 + i % 90).milliseconds) { }
  end

  tw.stop rescue nil
end

puts

# ============================================
# Summary
# ============================================
puts "=" * 60
puts "Summary"
puts "=" * 60
puts
puts "Short timers scheduling (lower is better):"
puts "  Standard:  #{standard_short.round(3)}ms"
puts "  Optimized: #{optimized_short.round(3)}ms"
puts
puts "Mixed duration timers (lower is better):"
puts "  Standard:  #{standard_mixed.round(3)}ms"
puts "  Optimized: #{optimized_mixed.round(3)}ms"
puts
puts "Schedule + cancel (lower is better):"
puts "  Standard:  #{standard_cancel.round(3)}ms"
puts "  Optimized: #{optimized_cancel.round(3)}ms"
puts
puts "Timer execution (lower is better):"
puts "  Standard:  #{standard_exec.round(3)}ms"
puts "  Optimized: N/A (missing advance)"
puts
puts "Interval timers (lower is better):"
puts "  Standard:  #{standard_interval.round(3)}ms"
puts "  Optimized: #{optimized_interval.round(3)}ms"
puts
puts "=" * 60
puts "Feature Comparison:"
puts "=" * 60
puts "| Feature              | Standard | Optimized |"
puts "|----------------------|----------|-----------|"
puts "| schedule()           | ✓        | ✓         |"
puts "| schedule_interval()  | ✓        | ✓         |"
puts "| cancel()             | ✓        | ✓         |"
puts "| advance() (testing)  | ✓        | ✗         |"
puts "| stop()               | ✓        | Partial   |"
puts "| stats()              | ✓        | ✓         |"
puts "| sync_callbacks       | ✓        | ✗         |"
puts "| Dynamic reconfig     | ✗        | ✓         |"
puts
puts "=" * 60
puts "Recommendation:"
puts "  - Standard TimerWheel (timer_wheel.cr) is more complete"
puts "  - Has testing support (advance, sync_callbacks)"
puts "  - Optimized is missing key testing features"
puts "  - Standard is recommended for correctness and testability"
puts "=" * 60
