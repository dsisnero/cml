# linda_tuple_space_system_from_book_chapter_9_042.cr - Compilation Issue

## Source File
`/Users/dominic/repos/github.com/dsisnero/cml/examples/how_to/failing/linda_tuple_space_system_from_book_chapter_9_042.cr`

## Error
```text
Showing last frame. Use --error-trace for full trace.

In examples/how_to/linda_tuple_space_system_from_book_chapter_9_042.cr:11:25

 11 | net_mbox = CML::Mailbox(NetworkMessage).new
                              ^-------------
Error: undefined constant NetworkMessage

```

## Example Content
```crystal
# linda_tuple_space_system_from_book_chapter_9_042.cr
# Extracted from: how_to.md
# Section: linda_tuple_space_system_from_book_chapter_9
# Lines: 1566-1577
#
# ----------------------------------------------------------

require "../../src/cml"

# Network buffer threads use mailboxes
net_mbox = CML::Mailbox(NetworkMessage).new

# Input buffer thread
CML.spawn do
  loop do
    msg = CML.sync(net_mbox.recv_evt)
    route_message(msg)
  end
end
```

## Analysis Needed
1. Identify the root cause of the compilation error
2. Determine if it's a:
   - Syntax issue in the example
   - Missing dependency or require
   - Type system limitation
   - API change needed
3. Propose a fix
