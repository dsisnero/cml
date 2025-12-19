# getting_started_002.cr
# Extracted from: how_to.md
# Section: getting_started
# Lines: 29-40
#
# ----------------------------------------------------------

require "../../src/cml"

# Spawn a thread
CML.spawn do
  puts "Hello from thread #{CML.get_tid}"
end

# Yield to other threads
CML.yield

# Wait a bit for threads to complete
sleep 0.1
