require "../src/cml"

def benchmark(name : String, iterations : Int32, &block)
  2.times { block.call }

  times = [] of Float64
  iterations.times do
    start = Time.instant
    block.call
    times << (Time.instant - start).total_milliseconds
  end

  avg = times.sum / times.size
  min = times.min
  max = times.max

  puts "#{name}:"
  puts "  avg: #{avg.round(3)}ms, min: #{min.round(3)}ms, max: #{max.round(3)}ms"
  avg
end

puts "=" * 60
puts "TimerWheel Benchmark"
puts "=" * 60
puts

ITERATIONS =      5
NUM_TIMERS = 10_000

schedule_short = benchmark("Schedule 10000 short timers", ITERATIONS) do
  tw = CML::TimerWheel.new(auto_advance: false, sync_callbacks: true)

  NUM_TIMERS.times do |i|
    tw.schedule((10 + (i % 90)).milliseconds) { }
  end

  tw.stop
end

puts

schedule_mixed = benchmark("Schedule 10000 mixed timers", ITERATIONS) do
  tw = CML::TimerWheel.new(auto_advance: false, sync_callbacks: true)

  NUM_TIMERS.times do |i|
    duration = case i % 4
               when 0 then (1 + i % 10).milliseconds
               when 1 then (100 + i % 900).milliseconds
               when 2 then (1 + i % 5).seconds
               else        (5 + i % 5).seconds
               end
    tw.schedule(duration) { }
  end

  tw.stop
end

puts

schedule_cancel = benchmark("Schedule and cancel 5000 timers", ITERATIONS) do
  tw = CML::TimerWheel.new(auto_advance: false, sync_callbacks: true)
  ids = Array(UInt64).new(5000)

  5000.times do |i|
    ids << tw.schedule((100 + i).milliseconds) { }
  end

  ids.each { |id| tw.cancel(id) }
  tw.stop
end

puts

advance_exec = benchmark("Execute 1000 timers via advance", ITERATIONS) do
  tw = CML::TimerWheel.new(auto_advance: false, sync_callbacks: true)
  executed = 0

  1000.times do |i|
    tw.schedule((1 + i % 100).milliseconds) { executed += 1 }
  end

  tw.advance(200.milliseconds)
  tw.stop
end

puts

intervals = benchmark("Schedule 1000 interval timers", ITERATIONS) do
  tw = CML::TimerWheel.new(auto_advance: false, sync_callbacks: true)

  1000.times do |i|
    tw.schedule_interval((10 + i % 90).milliseconds) { }
  end

  tw.stop
end

puts
puts "=" * 60
puts "Summary"
puts "=" * 60
puts "  schedule_short:  #{schedule_short.round(3)}ms"
puts "  schedule_mixed:  #{schedule_mixed.round(3)}ms"
puts "  schedule_cancel: #{schedule_cancel.round(3)}ms"
puts "  advance_exec:    #{advance_exec.round(3)}ms"
puts "  intervals:       #{intervals.round(3)}ms"
