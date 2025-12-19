# understanding_cmls_non-blocking_architecture_036.cr
# Extracted from: how_to.md
# Section: understanding_cmls_non-blocking_architecture
# Lines: 1391-1401
#
# ----------------------------------------------------------

require "../../src/cml"

# Describe multiple possible actions
choice = CML.choose([
  ch1.recv_evt,
  ch2.recv_evt,
  CML.timeout(1.second),
])

# Commit to exactly one
result = CML.sync(choice)
