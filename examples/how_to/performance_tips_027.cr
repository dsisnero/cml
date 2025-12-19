# performance_tips_027.cr
# Extracted from: how_to.md
# Section: performance_tips
# Lines: 1124-1146
#
# ----------------------------------------------------------

require "../../src/cml"

# Example: Polling before blocking
ch = CML::Chan(Int32).new

# Spawn a sender that sends after a short delay
CML.spawn do
  sleep 0.01
  CML.sync(ch.send_evt(42))
end

# Instead of always blocking:
# value = CML.sync(ch.recv_evt)

# Consider polling first:
if value = ch.recv_poll
  puts "Got value immediately: #{value}"
else
  puts "No value available, falling back to blocking..."
  # Fall back to blocking
  value = CML.sync(ch.recv_evt)
  puts "Got value after blocking: #{value}"
end