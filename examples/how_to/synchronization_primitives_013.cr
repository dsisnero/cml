# synchronization_primitives_013.cr
# Extracted from: how_to.md
# Section: synchronization_primitives
# Lines: 241-258
#
# ----------------------------------------------------------

require "../../src/cml"

# Create an IVar
ivar = CML::IVar(String).new

# Spawn writer
CML.spawn do
  sleep 0.1
  ivar.i_put("Hello from IVar!")
end

# Spawn reader
CML.spawn do
  value = CML.sync(ivar.i_get_evt)
  puts "IVar value: #{value}"
end

sleep 0.2
