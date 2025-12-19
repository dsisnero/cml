# synchronization_primitives_016.cr
# Extracted from: how_to.md
# Section: synchronization_primitives
# Lines: 309-328
#
# ----------------------------------------------------------

require "../../src/cml"

# Create barrier with combining function
barrier = CML::Barrier(Int32).new(->(x : Int32, y : Int32) { x + y }, 0)

# Spawn multiple threads that synchronize at barrier
5.times do |i|
  CML.spawn do
    enrollment = barrier.enroll
    puts "Thread #{i} waiting at barrier"

    # Each thread contributes its index
    result = enrollment.wait(i)
    puts "Thread #{i} passed barrier with total: #{result}"

    enrollment.resign
  end
end

sleep 0.2