# basic_channel_operations_003.cr
# Extracted from: how_to.md
# Section: basic_channel_operations
# Lines: 46-65
#
# ----------------------------------------------------------

require "../../src/cml"

# Create a channel for integers
ch = CML::Chan(Int32).new

# Spawn sender thread
CML.spawn do
  puts "Sender: about to send 42"
  CML.sync(ch.send_evt(42))
  puts "Sender: sent 42"
end

# Spawn receiver thread
CML.spawn do
  puts "Receiver: waiting for message"
  value = CML.sync(ch.recv_evt)
  puts "Receiver: got #{value}"
end

sleep 0.1