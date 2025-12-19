# linda_tuple_space_system_from_book_chapter_9_039.cr - Compilation Issue

## Source File
`/Users/dominic/repos/github.com/dsisnero/cml/examples/how_to/failing/linda_tuple_space_system_from_book_chapter_9_039.cr`

## Error
```text
Showing last frame. Use --error-trace for full trace.

In examples/how_to/linda_tuple_space_system_from_book_chapter_9_039.cr:11:20

 11 | req_ch = CML::Chan(Request).new
                         ^------
Error: undefined constant Request

```

## Example Content
```crystal
# linda_tuple_space_system_from_book_chapter_9_039.cr
# Extracted from: how_to.md
# Section: linda_tuple_space_system_from_book_chapter_9
# Lines: 1525-1532
#
# ----------------------------------------------------------

require "../../src/cml"

# Client ↔ Proxy communication
req_ch = CML::Chan(Request).new
reply_ch = CML::Chan(Array(ValAtom)).new

# Proxy ↔ Tuple Server communication
server_ch = CML::Chan(ServerMessage).new
```

## Analysis Needed
1. Identify the root cause of the compilation error
2. Determine if it's a:
   - Syntax issue in the example
   - Missing dependency or require
   - Type system limitation
   - API change needed
3. Propose a fix
