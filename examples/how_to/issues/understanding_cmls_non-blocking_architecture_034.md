# understanding_cmls_non-blocking_architecture_034.cr - Compilation Issue

## Source File
`/Users/dominic/repos/github.com/dsisnero/cml/examples/how_to/failing/understanding_cmls_non-blocking_architecture_034.cr`

## Error
```text
Showing last frame. Use --error-trace for full trace.

In examples/how_to/understanding_cmls_non-blocking_architecture_034.cr:15:7

 15 | evt = ch.send_evt(value)  # Just creates an event, doesn't block
            ^-
Error: undefined local variable or method 'ch' for top-level

```

## Example Content
```crystal
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
evt = ch.send_evt(value)  # Just creates an event, doesn't block
# ... do other work ...
result = CML.sync(evt)    # Only blocks here, when we choose to synchronize
```

## Analysis Needed
1. Identify the root cause of the compilation error
2. Determine if it's a:
   - Syntax issue in the example
   - Missing dependency or require
   - Type system limitation
   - API change needed
3. Propose a fix
