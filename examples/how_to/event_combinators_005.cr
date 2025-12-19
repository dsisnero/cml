# event_combinators_005.cr
# Extracted from: how_to.md
# Section: event_combinators
# Lines: 91-107
#
# ----------------------------------------------------------

require "../../src/cml"

# Always succeeds with a value
always_evt = CML.always(42)
value = CML.sync(always_evt) # => 42

# Never succeeds (blocks forever)
never_evt = CML.never
# CML.sync(never_evt)  # Would block forever

# Transform event result
ch = CML::Chan(Int32).new
CML.spawn { CML.sync(ch.send_evt(10)) }

transformed = CML.wrap(ch.recv_evt) { |x| x * 2 }
result = CML.sync(transformed) # => 20
puts "Transformed result: #{result}"
