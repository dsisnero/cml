require "./src/cml"

# Simple test to verify timer wheel integration
puts "Testing TimerWheel integration..."

# Test basic timeou
puts "\nTest 1: Basic timeout"
start_time = Time.monotonic
timeout_evt = CML.timeout(100.milliseconds)
result = CML.sync(timeout_evt)
elapsed = Time.monotonic - start_time
puts "Timeout result: #{result}"
puts "Elapsed time: #{elapsed.total_milliseconds.round(2)}ms"

# Test timer wheel statistics
puts "\nTest 2: Timer wheel statistics"
stats = CML.timer_wheel.stats
puts "Timer wheel stats: #{stats}"

puts "\nTest completed successfully!"
