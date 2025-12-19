# understanding_cmls_non-blocking_architecture_037.cr - Compilation Issue

## Source File
`/Users/dominic/repos/github.com/dsisnero/cml/examples/how_to/failing/understanding_cmls_non-blocking_architecture_037.cr`

## Error
```text
Showing last frame. Use --error-trace for full trace.

In examples/how_to/understanding_cmls_non-blocking_architecture_037.cr:11:10

 11 | stamps = antecedents.map { |port| CML.sync(port.recv_evt) }
               ^----------
Error: undefined local variable or method 'antecedents' for top-level

```

## Example Content
```crystal
# understanding_cmls_non-blocking_architecture_037.cr
# Extracted from: how_to.md
# Section: understanding_cmls_non-blocking_architecture
# Lines: 1428-1431
#
# ----------------------------------------------------------

require "../../src/cml"

# Each node does this:
stamps = antecedents.map { |port| CML.sync(port.recv_evt) }
```

## Analysis Needed
1. Identify the root cause of the compilation error
2. Determine if it's a:
   - Syntax issue in the example
   - Missing dependency or require
   - Type system limitation
   - API change needed
3. Propose a fix
