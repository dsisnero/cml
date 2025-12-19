# timeouts_and_timing_011.cr
# Extracted from: how_to.md
# Section: timeouts_and_timing
# Lines: 204-222
#
# ----------------------------------------------------------

require "../../src/cml"

ch = CML::Chan(String).new

# Spawn a slow sender
CML.spawn do
  sleep(2.seconds)
  CML.sync(ch.send_evt("slow message"))
end

# Race between channel receive and timeout
result = CML.sync(
  CML.choose([
    ch.recv_evt,
    CML.wrap(CML.timeout(1.second)) { "timeout" },
  ])
)

puts "Result: #{result}" # Will be "timeout" since sender takes 2 seconds