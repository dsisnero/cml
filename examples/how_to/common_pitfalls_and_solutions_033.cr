# common_pitfalls_and_solutions_033.cr
# Extracted from: how_to.md
# Section: common_pitfalls_and_solutions
# Lines: 1314-1335
#
# ----------------------------------------------------------

require "../../src/cml"

# Use bounded channels or flow control
class BoundedChan(T)
  def initialize(@capacity : Int32)
    @chan = CML::Chan(T).new
    @semaphore = CML::MVar(Int32).new(@capacity)
  end

  def send(value : T)
    # Wait for space
    CML.sync(@semaphore.m_take_evt)
    CML.sync(@chan.send_evt(value))
  end

  def recv : T
    value = CML.sync(@chan.recv_evt)
    # Release space
    @semaphore.m_put(1) # Synchronous put (no event needed)
    value
  end
end