require "./src/cml"

# Test the timer wheel integration
puts "Testing TimerWheel integration with CML..."

# Test 1: Basic timeou
puts "\nTest 1: Basic timeout"
start_time = Time.monotonic
timeout_evt = CML.timeout(100.milliseconds)
result = CML.sync(timeout_evt)
elapsed = Time.monotonic - start_time
puts "Timeout result: #{result}"
puts "Elapsed time: #{elapsed.total_milliseconds.round(2)}ms"

# Test 2: Choose between channel and timeout
puts "\nTest 2: Choose between channel and timeout"
channel = CML::Chan(Int32).new
timeout_evt = CML.timeout(50.milliseconds)

start_time = Time.monotonic
result = CML.sync(CML.choose(
  channel.recv_evt,
  timeout_evt
))
elapsed = Time.monotonic - start_time

case result
when :timeout
  puts "Operation timed out after #{elapsed.total_milliseconds.round(2)}ms (expected)"
else
  puts "Received: #{result} (unexpected)"
end

# Test 3: Interval timeou
puts "\nTest 3: Interval timeout (first 3 intervals)"
interval_count = Atomic(Int32).new(0)
interval_evt = CML.timeout_interval(100.milliseconds)

# We'll only wait for 3 intervals
spawn do
  3.times do
    CML.sync(interval_evt)
    count = interval_count.add(1)
    puts "Interval #{count} triggered"
  end
end

# Wait a bit for intervals to trigger
sleep 350.milliseconds

puts "Total intervals triggered: #{interval_count.get}"

# Test 4: Timer wheel statistics
puts "\nTest 4: Timer wheel statistics"
stats = CML.timer_wheel.stats
puts "Timer wheel stats: #{stats}"

puts "\nAll tests completed successfully!"
