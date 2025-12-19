# linda_tuple_space_system_from_book_chapter_9_040.cr
# Extracted from: how_to.md
# Section: linda_tuple_space_system_from_book_chapter_9
# Lines: 1535-1541
#
# ----------------------------------------------------------

require "../../src/cml"

# Broadcasting input requests to all servers
req_mch = CML.mchannel(InputRequest)

# Each proxy gets a port
proxy_port = req_mch.port
