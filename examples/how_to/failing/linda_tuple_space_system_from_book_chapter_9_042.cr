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