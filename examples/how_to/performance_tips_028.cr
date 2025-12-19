# performance_tips_028.cr
# Extracted from: how_to.md
# Section: performance_tips
# Lines: 1150-1182
#
# ----------------------------------------------------------

require "../../src/cml"

# Example: Using choice for batch operations
ch1 = CML::Chan(Int32).new
ch2 = CML::Chan(String).new

# Spawn senders with different delays
CML.spawn do
  sleep 0.02 # Slower sender
  CML.sync(ch1.send_evt(100))
  puts "ch1 sent 100"
end

CML.spawn do
  sleep 0.01 # Faster sender
  CML.sync(ch2.send_evt("hello"))
  puts "ch2 sent 'hello'"
end

# Instead of sequential receives (which would wait for ch1 then ch2):
# value1 = CML.sync(ch1.recv_evt)
# value2 = CML.sync(ch2.recv_evt)

# Use choice to receive from whichever channel is ready first:
result = CML.sync(
  CML.choose([
    CML.wrap(ch1.recv_evt) { |v| {:ch1, v.as(Int32 | String)} },
    CML.wrap(ch2.recv_evt) { |v| {:ch2, v.as(Int32 | String)} },
  ])
)

puts "Received from #{result[0]} with value #{result[1]}"
sleep 0.03 # Wait for other send to complete
