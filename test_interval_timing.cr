require "./src/cml"

# Test interval timer with precise timing measurements
spawn do
  puts "Starting precise interval timer test..."

  interval_ms = 100
  expected_count = 10

  # Create an interval timer even
  interval_event = CML::IntervalTimerEvent.new(CML.timer_wheel, interval_ms.milliseconds)

  start_time = Time.monotonic
  count = 0

  spawn do
    loop do
      result = CML.sync(
        CML.choose(
          interval_event,
          CML.timeout((expected_count * interval_ms + 500).milliseconds)
        )
      )

      if result == :timeou
        count += 1
        current_time = Time.monotonic
        elapsed_ms = (current_time - start_time).total_milliseconds
        avg_interval = elapsed_ms / coun
        puts "Interval #{count}: elapsed #{elapsed_ms.round(1)}ms, avg interval #{avg_interval.round(1)}ms"
      else
        puts "Main timeout reached after #{count} intervals"
        break
      end
    end
  end

  sleep((expected_count * interval_ms + 1000).milliseconds)
  puts "Test completed - total intervals: #{count}"
end

sleep(3.seconds)
