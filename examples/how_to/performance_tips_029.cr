# performance_tips_029.cr
# Extracted from: how_to.md
# Section: performance_tips
# Lines: 1186-1196
#
# ----------------------------------------------------------

require "../../src/cml"

# Dummy definitions for example compilation
def expensive_computation
  "result"
end

# Defer expensive computation until needed
expensive_evt = CML.guard do
  puts "Computing..."
  result = expensive_computation()
  CML.always(result)
end

# Computation only happens here:
value = CML.sync(expensive_evt)