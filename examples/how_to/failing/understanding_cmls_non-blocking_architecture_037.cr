# understanding_cmls_non-blocking_architecture_037.cr
# Extracted from: how_to.md
# Section: understanding_cmls_non-blocking_architecture
# Lines: 1428-1431
#
# ----------------------------------------------------------

require "../../src/cml"

# Each node does this:
stamps = antecedents.map { |port| CML.sync(port.recv_evt) }
