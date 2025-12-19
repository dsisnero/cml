# selective_communication_009.cr
# Extracted from: how_to.md
# Section: selective_communication
# Lines: 172-187
#
# ----------------------------------------------------------

require "../../src/cml"

ch_a = CML::Chan(String).new
ch_b = CML::Chan(String).new

CML.spawn { CML.sync(ch_a.send_evt("apple")) }
CML.spawn { CML.sync(ch_b.send_evt("banana")) }

# Different transformations for different channels
selection = CML.choose([
  CML.wrap(ch_a.recv_evt) { |s| "A: #{s.upcase}" },
  CML.wrap(ch_b.recv_evt) { |s| "B: #{s.reverse}" },
])

result = CML.sync(selection)
puts "Result: #{result}" # Could be "A: APPLE" or "B: ananab"
