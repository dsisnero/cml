# client-server_patterns_018.cr
# Extracted from: how_to.md
# Section: client-server_patterns
# Lines: 439-472
#
# ----------------------------------------------------------

require "../../src/cml"

class UniqueIdService
  @next_id : Int32 = 0
  @id_ch : CML::Chan(Int32)

  def initialize
    @id_ch = CML::Chan(Int32).new

    # Server thread
    CML.spawn do
      loop do
        CML.sync(@id_ch.send_evt(@next_id))
        @next_id += 1
      end
    end
  end

  def next_id : Int32
    CML.sync(@id_ch.recv_evt)
  end
end

# Usage
service = UniqueIdService.new

5.times do |i|
  CML.spawn do
    id = service.next_id
    puts "Thread #{i} got ID: #{id}"
  end
end

sleep 0.1