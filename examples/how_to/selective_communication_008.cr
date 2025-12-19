# selective_communication_008.cr
# Extracted from: how_to.md
# Section: selective_communication
# Lines: 146-168
#
# ----------------------------------------------------------

require "../../src/cml"

ch1 = CML::Chan(Int32).new
ch2 = CML::Chan(Int32).new

# Spawn senders with delays
CML.spawn do
  sleep 0.05
  CML.sync(ch1.send_evt(1))
end

CML.spawn do
  sleep 0.01 # This sender is faster
  CML.sync(ch2.send_evt(2))
end

# Select will choose the first available event
result = CML.select([
  ch1.recv_evt,
  ch2.recv_evt,
])

puts "Selected: #{result}" # Likely 2 from ch2
