# synchronization_primitives_014.cr
# Extracted from: how_to.md
# Section: synchronization_primitives
# Lines: 262-280
#
# ----------------------------------------------------------

require "../../src/cml"

# Create MVar with initial value
mvar = CML::MVar(Int32).new(0)

# Spawn multiple updaters
3.times do |i|
  CML.spawn do
    # Take current value, put new value
    current = CML.sync(mvar.m_take_evt)
    new_value = current + 1
    mvar.m_put(new_value) # Synchronous put (no event needed)
    puts "Thread #{i}: #{current} -> #{new_value}"
  end
end

sleep 0.2
final = CML.sync(mvar.m_get_evt)
puts "Final value: #{final}" # Should be 3