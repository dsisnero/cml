# basic_channel_operations_004.cr
# Extracted from: how_to.md
# Section: basic_channel_operations
# Lines: 69-85
#
# ----------------------------------------------------------

require "../../src/cml"

ch = CML::Chan(String).new

# Try to send without blocking
if ch.send_poll("hello")
  puts "Send succeeded immediately"
else
  puts "Send would block"
end

# Try to receive without blocking
if value = ch.recv_poll
  puts "Got: #{value}"
else
  puts "No message available"
end