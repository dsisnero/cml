#!/usr/bin/env crystal
# Example demonstrating CML Barrier and join_evt synchronization primitives

require "../src/cml"
require "../src/cml/barrier"

# Barrier Example
# ===============
# A barrier is a synchronization primitive where a group of fibers
# wait until all enrolled fibers have reached the barrier point.
# When all fibers arrive, an update function is applied to the shared state
# and all fibers are released.

puts "=== Barrier Example ==="
puts "Demonstrating how multiple fibers synchronize at a barrier point"

# Create a counting barrier that increments its state each round
barrier = CML.counting_barrier(0)

# Create 3 enrollments in the barrier
enrollments = Array(CML::Enrollment(Int32)).new(3)
3.times do |_|
  enrollments << barrier.enroll
end

# Spawn 3 fibers that will synchronize at the barrier
fibers = [] of CML::ThreadId
3.times do |i|
  tid = CML.spawn do
    puts "Fiber #{i}: Starting work before barrier"
    sleep((i + 1).seconds * 0.1) # Simulate different work durations

    puts "Fiber #{i}: Reached barrier, waiting for others..."
    round = enrollments[i].wait
    puts "Fiber #{i}: Released from barrier (round #{round})"

    # Do some work after barrier
    sleep(0.05.seconds)
    puts "Fiber #{i}: Finished work after barrier"
  end
  fibers << tid
end

# Wait for all fibers to complete using join_evt
puts "\nWaiting for all fibers to complete..."
fibers.each do |tid|
  CML.sync(CML.join_evt(tid))
end
puts "All fibers completed!"

# Barrier with Shared State Example
# =================================
puts "\n=== Barrier with Shared State Example ==="
puts "Demonstrating barrier with custom update function"

# Create a barrier with a custom update function
# The state will be a hash tracking which fibers have passed through
state_barrier = CML.barrier(
  ->(state : Hash(String, Array(Int32))) do
    # Update function: add a new round entry
    new_state = state.dup
    new_state["round_#{state.size + 1}"] = [] of Int32
    new_state
  end,
  Hash(String, Array(Int32)).new
)

# Create enrollments
enrollments2 = Array(CML::Enrollment(Hash(String, Array(Int32)))).new(4)
4.times do
  enrollments2 << state_barrier.enroll
end

# Spawn fibers that will pass through the barrier multiple times
puts "\nRunning 4 fibers through 3 barrier rounds:"
fibers2 = [] of CML::ThreadId
4.times do |i|
  tid = CML.spawn do
    3.times do |round|
      sleep(i.seconds * 0.05) # Stagger start times

      # Record that this fiber is entering round
      puts "  Fiber #{i}: Entering barrier round #{round + 1}"

      # Wait at barrier
      state = enrollments2[i].wait

      # Check what round we're in
      current_round = state.size
      puts "  Fiber #{i}: Released from barrier round #{current_round}"
    end
  end
  fibers2 << tid
end

# Wait for all fibers
fibers2.each do |tid|
  CML.sync(CML.join_evt(tid))
end

# join_evt Example with choose
# ============================
puts "\n=== join_evt with choose Example ==="
puts "Demonstrating waiting for multiple fibers with timeout"

# Spawn fibers with different completion times
fast_fiber = CML.spawn do
  puts "  Fast fiber: Starting"
  sleep(0.1.seconds)
  puts "  Fast fiber: Finished"
end

slow_fiber = CML.spawn do
  puts "  Slow fiber: Starting"
  sleep(0.5.seconds)
  puts "  Slow fiber: Finished"
end

# Use choose to wait for either fiber to complete or timeout
puts "\nWaiting for first fiber to complete (with 300ms timeout)..."
result = CML.sync(CML.choose([
  CML.wrap(CML.join_evt(fast_fiber)) { :fast_completed },
  CML.wrap(CML.join_evt(slow_fiber)) { :slow_completed },
  CML.wrap(CML.timeout(300.milliseconds)) { :timeout },
]))

case result
when :fast_completed
  puts "Result: Fast fiber completed first!"
when :slow_completed
  puts "Result: Slow fiber completed first!"
when :timeout
  puts "Result: Timeout occurred before any fiber completed"
end

# Wait for remaining fibers
puts "\nWaiting for any remaining fibers..."
remaining = [fast_fiber, slow_fiber].select do |tid|
  # Check if fiber is still alive by trying to join with short timeout
  begin
    # Try to join with a short timeout
    result = CML.sync(CML.choose([
      CML.wrap(CML.join_evt(tid)) { :completed },
      CML.wrap(CML.timeout(10.milliseconds)) { :timeout },
    ]))

    result == :completed ? false : true
  rescue
    true # Fiber still running (error occurred)
  end
end

if remaining.empty?
  puts "All fibers have completed"
else
  puts "Waiting for #{remaining.size} remaining fiber(s)..."
  remaining.each do |tid|
    CML.sync(CML.join_evt(tid))
  end
end

# Complex Example: Combining Barrier and join_evt
# ===============================================
puts "\n=== Complex Example: Worker Pool with Barrier Synchronization ==="

# Create a worker pool that processes tasks in phases
class WorkerPool
  def initialize(n_workers : Int32)
    # Create a barrier for synchronizing phases
    @phase_barrier = CML.counting_barrier(0)

    # Create worker enrollments
    enrollments = [] of CML::Enrollment(Int32)
    n_workers.times { enrollments << @phase_barrier.enroll }

    # Spawn workers
    @workers = [] of CML::ThreadId
    n_workers.times do |i|
      tid = CML.spawn do
        worker_id = i
        3.times do |phase|
          # Simulate work in this phase
          sleep(rand.seconds * 0.2)
          puts "  Worker #{worker_id}: Finished phase #{phase} work"

          # Synchronize with other workers at barrier
          round = enrollments[i].wait
          puts "  Worker #{worker_id}: All workers reached phase #{phase} (barrier round #{round})"
        end
        puts "  Worker #{worker_id}: Completed all phases"
      end
      @workers << tid
    end
  end

  def wait_for_completion
    # Wait for all workers using join_evt
    @workers.each do |tid|
      CML.sync(CML.join_evt(tid))
    end
    puts "All workers completed!"
  end
end

puts "\nCreating worker pool with 4 workers..."
pool = WorkerPool.new(4)
puts "Waiting for worker pool to complete all phases..."
pool.wait_for_completion

puts "\n=== Example Complete ==="
