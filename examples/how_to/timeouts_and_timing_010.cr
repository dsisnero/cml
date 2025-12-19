# timeouts_and_timing_010.cr
# Extracted from: how_to.md
# Section: timeouts_and_timing
# Lines: 193-200
#
# ----------------------------------------------------------

require "../../src/cml"

# Timeout after 1 second
timeout_evt = CML.timeout(1.second)

# sync on timeout returns nil when timeout fires
result = CML.sync(timeout_evt)
puts "Timeout occurred" if result.nil?