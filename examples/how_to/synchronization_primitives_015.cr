# synchronization_primitives_015.cr
# Extracted from: how_to.md
# Section: synchronization_primitives
# Lines: 284-305
#
# ----------------------------------------------------------

require "../../src/cml"

# Create mailbox
mbox = CML::Mailbox(String).new

# Spawn multiple senders (non-blocking)
5.times do |i|
  CML.spawn do
    mbox.send("Message #{i}")
    puts "Sent message #{i}"
  end
end

# Spawn receiver
CML.spawn do
  5.times do
    msg = CML.sync(mbox.recv_evt)
    puts "Received: #{msg}"
  end
end

sleep 0.1
