require "./src/cml"

# Test interval timer functionality
spawn do
  puts "Starting interval timer test..."

  # Create an interval timer even
  interval_event = CML::IntervalTimerEvent.new(CML.timer_wheel, 100.milliseconds)

  # Try to use it in a choose
  result = CML.sync(
    CML.choose(
      interval_event,
      CML.timeout(1.second)
    )
  )

  puts "Interval timer result: #{result}"

  # Test multiple intervals
  count = 0
  spawn do
    loop do
      result = CML.sync(
        CML.choose(
          interval_event,
          CML.timeout(500.milliseconds)
        )
      )

      if result == :timeou
        count += 1
        puts "Interval timer fired! Count: #{count}"
      else
        puts "Main timeout reached"
        break
      end
    end
  end

  sleep 2.seconds
  puts "Test completed"
end

sleep 3.seconds
