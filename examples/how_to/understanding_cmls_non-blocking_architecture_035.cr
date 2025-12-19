# understanding_cmls_non-blocking_architecture_035.cr
# Extracted from: how_to.md
# Section: understanding_cmls_non-blocking_architecture
# Lines: 1365-1380
#
# ----------------------------------------------------------

require "../../src/cml"

# Phase 1: Non-blocking registration
def try_operation
  # Create event without blocking
  evt = some_operation_evt()

  # Try to complete immediately
  if can_complete_now?(evt)
    complete_immediately(evt)
  else
    # Phase 2: Block only if necessary
    register_for_completion(evt)
    # Fiber yields here, other work continues
  end
end