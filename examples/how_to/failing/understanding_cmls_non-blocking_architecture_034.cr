# understanding_cmls_non-blocking_architecture_034.cr
# Extracted from: how_to.md
# Section: understanding_cmls_non-blocking_architecture
# Lines: 1345-1354
#
# ----------------------------------------------------------

require "../../src/cml"

# Traditional approach (blocks during registration):
# thread1: ch.send(value)  # BLOCKS until someone receives
# thread2: ch.recv         # BLOCKS until someone sends

# CML approach (non-blocking registration):
evt = ch.send_evt(value) # Just creates an event, doesn't block
# ... do other work ...
result = CML.sync(evt) # Only blocks here, when we choose to synchronize
