# event_combinators_006.cr
# Extracted from: how_to.md
# Section: event_combinators
# Lines: 111-120
#
# ----------------------------------------------------------

require "../../src/cml"

# Dummy definitions for example compilation
def compute_expensive_value
  42
end

# Lazy event creation
expensive_evt = CML.guard do
  puts "Computing expensive value..."
  CML.always(compute_expensive_value())
end

# The computation only happens when we sync
result = CML.sync(expensive_evt)
