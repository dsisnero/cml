# event_combinators_007.cr
# Extracted from: how_to.md
# Section: event_combinators
# Lines: 124-140
#
# ----------------------------------------------------------

require "../../src/cml"

ch1 = CML::Chan(Int32).new
ch2 = CML::Chan(String).new

# Spawn senders
CML.spawn { CML.sync(ch1.send_evt(100)) }
CML.spawn { CML.sync(ch2.send_evt("done")) }

# Choose between receiving from either channel
choice = CML.choose([
  CML.wrap(ch1.recv_evt) { |x| "Number: #{x}" },
  CML.wrap(ch2.recv_evt) { |s| "String: #{s}" },
])

result = CML.sync(choice)
puts "Chose: #{result}" # Could be either "Number: 100" or "String: done"