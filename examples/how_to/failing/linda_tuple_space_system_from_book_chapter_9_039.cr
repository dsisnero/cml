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
