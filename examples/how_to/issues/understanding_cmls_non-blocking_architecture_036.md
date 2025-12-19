# understanding_cmls_non-blocking_architecture_036.cr - Compilation Issue

## Source File
`/Users/dominic/repos/github.com/dsisnero/cml/examples/how_to/failing/understanding_cmls_non-blocking_architecture_036.cr`

## Error
```text
Showing last frame. Use --error-trace for full trace.

In examples/how_to/understanding_cmls_non-blocking_architecture_036.cr:12:3

 12 | ch1.recv_evt,
      ^--
Error: undefined local variable or method 'ch1' for top-level

```

## Example Content
```crystal
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
  CML.timeout(1.second)
])

# Commit to exactly one
result = CML.sync(choice)
```

## Analysis Needed
1. Identify the root cause of the compilation error
2. Determine if it's a:
   - Syntax issue in the example
   - Missing dependency or require
   - Type system limitation
   - API change needed
3. Propose a fix
