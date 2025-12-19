# linda_tuple_space_system_from_book_chapter_9_041.cr
# Extracted from: how_to.md
# Section: linda_tuple_space_system_from_book_chapter_9
# Lines: 1544-1563
#
# ----------------------------------------------------------

require "../../src/cml"

def in_evt(template : Template) : CML::Event(Array(ValAtom))
  CML.with_nack do |nack|
    # Create transaction
    reply = CML.channel(Array(ValAtom))
    waiter_id = next_id()

    # Broadcast request to all servers
    CML.sync(@req_ch.send_evt(WaitRequest.new(template, reply, true, waiter_id)))

    # Cancel if nack fires
    CML.spawn do
      CML.sync(nack)
      CML.sync(@req_ch.send_evt(CancelRequest.new(waiter_id)))
    end

    reply.recv_evt
  end
end