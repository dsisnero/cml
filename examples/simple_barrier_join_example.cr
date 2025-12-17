#!/usr/bin/env crystal

# Simple Barrier and join_evt Example
# ====================================
# This example demonstrates the basic usage of CML's barrier synchronization
# and thread join events.

require "../src/cml"

puts "=== CML Barrier and join_evt Example ===\n"

# Example 1: Basic Barrier Usage
# ==============================
puts "1. Basic Barrier Example"
puts "------------------------"

# Create a barrier that waits for 3 threads
barrier = CML.counting_barrier(0)
puts "Created barrier for 3 threads"

# Create enrollments for each thread
enrollments = [] of CML::Barrier::Enrollment(Int32)
3.times { enrollments << barrier.enroll }

# Spawn 3 worker threads
threads = [] of CML::Thread::Id
3.times do |i|
  tid = CML.spawn do
    puts "  Thread #{i}: Starting work"
    sleep(rand.seconds * 0.2) # Simulate some work

    puts "  Thread #{i}: Reaching barrier"
    round = enrollments[i].wait
    puts "  Thread #{i}: Passed barrier (round #{round})"

    puts "  Thread #{i}: Finished"
  end
  threads << tid
end

# Wait for all threads to complete
puts "\nMain thread: Waiting for all workers..."
threads.each do |tid|
  CML.sync(CML.join_evt(tid))
end
puts "All threads completed!\n"

# Example 2: Simple join_evt Usage
# ================================
puts "\n2. Simple join_evt Example"
puts "--------------------------"

# Spawn a worker thread
worker = CML.spawn do
  puts "  Worker: Starting task"
  sleep(0.3.seconds)
  puts "  Worker: Task completed"
  :success
end

# Wait for worker using join_evt
puts "Main thread: Waiting for worker..."
CML.sync(CML.join_evt(worker))
puts "Worker thread completed\n"

# Example 3: Combining Barrier and join_evt
# =========================================
puts "\n3. Combined Barrier and join_evt Example"
puts "----------------------------------------"

# Create a worker pool with barrier synchronization
class WorkerPool
  def initialize(n_workers : Int32)
    @barrier = CML.counting_barrier(0)
    @enrollments = [] of CML::Barrier::Enrollment(Int32)
    n_workers.times { @enrollments << @barrier.enroll }

    @workers = [] of CML::Thread::Id
    n_workers.times do |i|
      tid = CML.spawn do
        worker_id = i
        2.times do |phase|
          # Simulate work
          sleep(rand.seconds * 0.1)
          puts "  Worker #{worker_id}: Finished phase #{phase}"

          # Synchronize at barrier
          round = @enrollments[i].wait
          puts "  Worker #{worker_id}: All workers reached phase #{phase} (round #{round})"
        end
        puts "  Worker #{worker_id}: All phases complete"
      end
      @workers << tid
    end
  end

  def wait_for_completion
    @workers.each do |tid|
      CML.sync(CML.join_evt(tid))
    end
    puts "All workers in pool completed!"
  end
end

# Create and run worker pool
puts "Creating worker pool with 3 workers..."
pool = WorkerPool.new(3)
pool.wait_for_completion

puts "\n=== Example Complete ==="
