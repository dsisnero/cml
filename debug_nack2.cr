require "./src/cml"

cleanup_called = Atomic(Bool).new(false)
ch = CML::Chan(Int32).new

puts "Creating nacked event..."
nacked = CML.nack(ch.send_evt(42)) do
  puts "CLEANUP CALLED!"
  cleanup_called.set(true)
end

puts "Creating choice..."
choice = CML.choose([
  CML.wrap(nacked) { |_| :nacked },
  CML.timeout(0.5.seconds),
])

puts "Calling sync..."
result = CML.sync(choice)
puts "Result: #{result}"
puts "Cleanup called: #{cleanup_called.get}"

# Give time for cleanup to run
sleep(0.5.seconds)
puts "After sleep - Cleanup called: #{cleanup_called.get}"