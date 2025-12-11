# Barrier Alone Example for CML
# Demonstrates using CML barriers without join_evt for synchronization

require "../src/cml"
require "../src/cml/barrier"

def simple_barrier_example
  puts "=== Simple Barrier Example ==="

  # Create a barrier for 3 workers
  barrier = CML.counting_barrier(0)

  # Create enrollments for each worker
  enrollments = Array(CML::Enrollment(Int32)).new(3)
  3.times do |_|
    enrollments << barrier.enroll
  end

  3.times do |i|
    spawn do
      puts "Worker #{i}: Starting work..."
      sleep((i + 1) * 0.1) # Simulate different work durations
      puts "Worker #{i}: Finished work, waiting at barrier..."

      # Wait at the barrier - all workers must reach this point
      round = enrollments[i].wait

      puts "Worker #{i}: Barrier crossed! (round #{round}) Continuing..."
      sleep(0.05)
      puts "Worker #{i}: Done!"
    end
  end

  sleep(1)
  puts "All workers completed!\n\n"
end

def multi_phase_barrier_example
  puts "=== Multi-Phase Barrier Example ==="

  # Create a barrier for 4 workers
  barrier = CML.counting_barrier(0)

  # Create enrollments for each worker
  enrollments = Array(CML::Enrollment(Int32)).new(4)
  4.times do |_|
    enrollments << barrier.enroll
  end

  4.times do |i|
    spawn do
      # Phase 1
      puts "Worker #{i}: Phase 1 - Starting..."
      sleep((i + 1) * 0.05)
      puts "Worker #{i}: Phase 1 - Finished, waiting at barrier..."
      round = enrollments[i].wait

      # Phase 2 (all workers start together after barrier)
      puts "Worker #{i}: Phase 2 - Starting after barrier (round #{round})..."
      sleep((4 - i) * 0.05) # Reverse order for variety
      puts "Worker #{i}: Phase 2 - Finished, waiting at barrier..."
      round = enrollments[i].wait

      # Phase 3
      puts "Worker #{i}: Phase 3 - Starting after second barrier (round #{round})..."
      sleep(0.1)
      puts "Worker #{i}: Phase 3 - Finished, waiting at barrier..."
      enrollments[i].wait

      puts "Worker #{i}: All phases complete!"
    end
  end

  sleep(2)
  puts "Multi-phase example completed!\n\n"
end

def barrier_with_timeout_example
  puts "=== Barrier with Timeout Example ==="

  # Create a barrier for 3 workers
  barrier = CML.counting_barrier(0)

  # Create enrollments for each worker
  enrollments = Array(CML::Enrollment(Int32)).new(3)
  3.times do |_|
    enrollments << barrier.enroll
  end

  # Worker 0 - normal
  spawn do
    puts "Worker 0: Starting work..."
    sleep(0.2)
    puts "Worker 0: Finished work, waiting at barrier..."
    round = enrollments[0].wait
    puts "Worker 0: Barrier crossed! (round #{round})"
  end

  # Worker 1 - normal
  spawn do
    puts "Worker 1: Starting work..."
    sleep(0.1)
    puts "Worker 1: Finished work, waiting at barrier..."
    round = enrollments[1].wait
    puts "Worker 1: Barrier crossed! (round #{round})"
  end

  # Worker 2 - will timeout
  spawn do
    puts "Worker 2: Starting work (will be slow)..."
    sleep(1) # Too slow!
    puts "Worker 2: Finally finished work..."
    begin
      round = enrollments[2].wait
      puts "Worker 2: Barrier crossed (unlikely to reach here) (round #{round})"
    rescue ex
      puts "Worker 2: Exception: #{ex.message}"
    end
  end

  # Main thread waits with timeout
  spawn do
    puts "Main: Waiting for barrier with 0.5 second timeout..."

    # Create a choice between barrier and timeout
    # Note: We can't directly wrap a barrier, but we can create a custom event
    # For this example, we'll just use a simple timeout check
    begin
      # Try to wait with a timeout
      CML.sync(CML.timeout(0.5.seconds))
      puts "Main: Timeout! Not all workers reached the barrier in time."
    rescue ex
      puts "Main: Exception: #{ex.message}"
    end
  end

  sleep(2)
  puts "Timeout example completed!\n\n"
end

def barrier_for_data_processing
  puts "=== Barrier for Data Processing Example ==="

  # Simulate processing data in parallel with barrier synchronization
  data = (1..10).to_a
  results = [] of Int32
  results_mutex = Mutex.new

  # Create a barrier for 3 processing threads
  barrier = CML.counting_barrier(0)

  # Create enrollments for each processor
  enrollments = Array(CML::Enrollment(Int32)).new(3)
  3.times do |_|
    enrollments << barrier.enroll
  end

  3.times do |i|
    spawn do
      # Each thread processes a chunk of data
      start_idx = i * 3
      end_idx = start_idx + 2
      chunk = data[start_idx..end_idx] rescue data[start_idx..]

      puts "Processor #{i}: Processing chunk #{chunk}..."
      sleep(0.1 * (i + 1))

      processed = chunk.map { |x| x * 2 }

      results_mutex.synchronize do
        results.concat(processed)
      end

      puts "Processor #{i}: Finished processing, waiting at barrier..."
      round = enrollments[i].wait

      # After barrier, all results are available
      puts "Processor #{i}: Barrier crossed! (round #{round}) All results: #{results.sort}"
    end
  end

  sleep(1)
  puts "Data processing complete. Final results: #{results.sort}\n\n"
end

def reusable_barrier_example
  puts "=== Reusable Barrier Example ==="

  # Create a barrier for 2 workers
  barrier = CML.counting_barrier(0)

  # Create enrollments for each worker
  enrollments = Array(CML::Enrollment(Int32)).new(2)
  2.times do |_|
    enrollments << barrier.enroll
  end

  # This barrier can be reused multiple times
  3.times do |round|
    puts "\n--- Round #{round + 1} ---"

    2.times do |i|
      spawn do
        puts "Worker #{i}: Round #{round + 1} - Starting..."
        sleep((i + 1) * 0.1)
        puts "Worker #{i}: Round #{round + 1} - Finished, waiting at barrier..."
        round_num = enrollments[i].wait
        puts "Worker #{i}: Round #{round + 1} - Barrier crossed! (barrier round #{round_num})"
      end
    end

    sleep(0.5)
  end

  puts "\nReusable barrier example completed!"
end

# Run all examples
puts "CML Barrier Alone Examples\n" + "=" * 30 + "\n\n"

simple_barrier_example
multi_phase_barrier_example
barrier_with_timeout_example
barrier_for_data_processing
reusable_barrier_example

puts "\n" + "=" * 30
puts "All barrier examples completed successfully!"
