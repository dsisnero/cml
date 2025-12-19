# timeouts_and_timing_012.cr
# Extracted from: how_to.md
# Section: timeouts_and_timing
# Lines: 226-235
#
# ----------------------------------------------------------

require "../../src/cml"

# Event that fires at specific time
target_time = Time.utc + 5.seconds
at_time_evt = CML.at_time(target_time)

CML.spawn do
  CML.sync(at_time_evt)
  puts "5 seconds have passed!"
end
