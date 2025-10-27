module CML
  # Hierarchical timing wheel for efficient timeout management.
  # This class is thread-safe.
  class TimerWheel
    getter current_time : UInt64
    getter? running : Bool

    # Represents a scheduled timer.
    record TimerEntry,
      id : UInt64,
      callback : Proc(Nil),
      expiration : UInt64,
      interval : UInt64? = nil

    getter wheel_config : Array(Tuple(Int32, Int32))

    # Initializes the timer wheel.
    #
    # - tick_duration: The resolution of the timer wheel.
    # - wheel_config: Configuration for each level of the wheel, defining
    #   the number of slots and the bit-width for that level.
    def initialize(
      @tick_duration : Time::Span = 1.millisecond,
      @wheel_config : Array(Tuple(Int32, Int32)) = [
        {256, 8}, # Level 0: 256 slots, 8 bits
        {64, 6},  # Level 1: 64 slots, 6 bits
        {64, 6},  # Level 2: 64 slots, 6 bits
        {64, 6},  # Level 3: 64 slots, 6 bits
      ]
    )
      @current_time = 0_u64
      @wheel_slots = [] of Array(Array(TimerEntry))
      @wheel_offsets = [] of UInt64
      @wheel_masks = [] of UInt64
      @wheel_shifts = [] of Int32
      @pending_timers = [] of TimerEntry
      @next_id = 0_u64
      @mutex = Mutex.new
      @running = true

      setup_wheels
      spawn { process_timers_loop }
    end

    # Schedules a one-time timeout.
    def schedule(timeout : Time::Span, &callback : ->) : UInt64
      @mutex.synchronize do
        add_timer_internal(timeout, nil, callback)
      end
    end

    # Schedules a recurring timer.
    def schedule_interval(interval : Time::Span, &callback : ->) : UInt64
      @mutex.synchronize do
        add_timer_internal(interval, interval, callback)
      end
    end

    # Cancels a scheduled timer. Returns true if found and cancelled.
    def cancel(timer_id : UInt64) : Bool
      @mutex.synchronize do
        cancel_internal(timer_id)
      end
    end

    # Advances the timer wheel by the given duration.
    def advance(by time : Time::Span) : Nil
      @mutex.synchronize do
        advance_internal(time)
      end
    end

    # Stops the timer wheel and its background processing fiber.
    def stop : Nil
      @mutex.synchronize do
        stop_internal
      end
    end

    # Returns statistics about the timer wheel.
    def stats : Hash(Symbol, Int32 | Array(Int32) | UInt64)
      @mutex.synchronize do
        stats_internal
      end
    end

    # Returns the optimal sleep duration until the next timer is due.
    def process_and_get_next_sleep_duration : Time::Span
      @mutex.synchronize do
        process_expired_internal
        calculate_next_sleep_duration_internal
      end
    end

    # Get the tick duration for external use.
    def tick_duration : Time::Span
      @tick_duration
    end

    # ===================================================================
    # Private, Non-Locking Implementation
    #
    # Methods below this line assume the caller holds the mutex.
    # They should NOT be called directly from outside the class.
    # ===================================================================

    private def setup_wheels
      total_shift = 0
      @wheel_config.each_with_index do |(slots, bits), level|
        @wheel_slots << Array(Array(TimerEntry)).new(slots) { [] of TimerEntry }
        @wheel_masks << (slots - 1).to_u64
        @wheel_shifts << total_shift
        @wheel_offsets << (level == 0 ? 0_u64 : 1_u64 << total_shift)
        total_shift += bits
      end
    end

    private def add_timer_internal(timeout : Time::Span, interval : Time::Span?, callback : ->) : UInt64
      timeout_ticks = (timeout / @tick_duration).to_i.to_u64
      raise ArgumentError.new("Timeout must be positive") if timeout_ticks == 0

      expiration = @current_time + timeout_ticks
      interval_ticks = interval ? (interval / @tick_duration).to_i.to_u64 : nil

      timer_id = @next_id
      @next_id += 1

      entry = TimerEntry.new(
        id: timer_id,
        callback: callback,
        expiration: expiration,
        interval: interval_ticks
      )

      add_to_wheel_internal(entry) || @pending_timers << entry
      timer_id
    end

    private def cancel_internal(timer_id : UInt64) : Bool
      found = false
      @wheel_slots.each do |wheel|
        wheel.each do |slot|
          original_size = slot.size
          slot.reject! { |entry| entry.id == timer_id }
          found = true if slot.size < original_size
        end
      end
      original_pending_size = @pending_timers.size
      @pending_timers.reject! { |entry| entry.id == timer_id }
      found = true if @pending_timers.size < original_pending_size
      found
    end

    private def advance_internal(time : Time::Span)
      ticks = (time / @tick_duration).to_i.to_u64
      return if ticks == 0

      end_time = @current_time + ticks
      while @current_time < end_time
        @current_time += 1
        process_current_tick_internal
      end
    end

    private def stop_internal
      @running = false
      @wheel_slots.each(&.clear)
      @pending_timers.clear
    end

    private def stats_internal
      total_timers = @pending_timers.size
      wheel_counts = @wheel_slots.map { |wheel| wheel.sum(&.size) }

      {
        pending:      total_timers,
        wheel_levels: wheel_counts,
        current_time: @current_time,
      }.to_h
    end

    private def add_to_wheel_internal(entry : TimerEntry) : Bool
      expiration = entry.expiration
      return false if expiration < @current_time

      delta = expiration - @current_time

      @wheel_config.each_with_index do |(slots, bits), level|
        # Determine the maximum number of ticks this level can represent.
        # For the last level, this is effectively infinite.
        max_ticks_for_level = if level + 1 < @wheel_config.size
                                1_u64 << @wheel_shifts[level + 1]
                              else
                                UInt64::MAX
                              end

        if delta < max_ticks_for_level
          shift = @wheel_shifts[level]
          mask = @wheel_masks[level]
          slot_index = ((expiration >> shift) & mask).to_i

          @wheel_slots[level][slot_index] << entry
          return true
        end
      end

      false
    end

    private def process_current_tick_internal
      level0_mask = @wheel_masks[0]
      slot_index0 = (@current_time & level0_mask).to_i
      process_slot_internal(0, slot_index0)

      (1...@wheel_config.size).each do |level|
        level_shift = @wheel_shifts[level]
        if (@current_time & ((1_u64 << level_shift) - 1)) == 0
          level_mask = @wheel_masks[level]
          slot_index = ((@current_time >> level_shift) & level_mask).to_i
          cascade_timers_internal(level, slot_index)
        else
          break
        end
      end

      retry_pending_timers_internal
    end

    private def process_slot_internal(level : Int32, slot_index : Int32)
      slot = @wheel_slots[level][slot_index]
      return if slot.empty?

      expired = [] of TimerEntry
      remaining = [] of TimerEntry

      slot.each do |entry|
        if entry.expiration <= @current_time
          expired << entry
        else
          remaining << entry
        end
      end

      @wheel_slots[level][slot_index] = remaining

      expired.each do |entry|
        begin
          entry.callback.call
        rescue ex
          # Log or handle callback errors
        end

        if interval = entry.interval
          new_entry = TimerEntry.new(
            id: entry.id,
            callback: entry.callback,
            expiration: @current_time + interval,
            interval: interval
          )
          add_to_wheel_internal(new_entry) || @pending_timers << new_entry
        end
      end
    end

    private def cascade_timers_internal(level : Int32, slot_index : Int32)
      slot = @wheel_slots[level][slot_index]
      return if slot.empty?

      @wheel_slots[level][slot_index] = [] of TimerEntry
      slot.each do |entry|
        add_to_wheel_internal(entry) || @pending_timers << entry
      end
    end

    private def retry_pending_timers_internal
      return if @pending_timers.empty?
      remaining = [] of TimerEntry
      @pending_timers.each do |entry|
        add_to_wheel_internal(entry) || remaining << entry
      end
      @pending_timers = remaining
    end

    private def next_expiration_time_internal : UInt64?
      min_time = nil

      # Check pending timers first, as they might be sooner
      @pending_timers.each do |timer|
        min_time = timer.expiration if min_time.nil? || timer.expiration < min_time
      end

      # Check wheel slots
      @wheel_slots.each_with_index do |wheel, level|
        # Optimization: only check slots that could possibly contain the next timer
        current_slot_index = ((@current_time >> @wheel_shifts[level]) & @wheel_masks[level]).to_i
        slots_in_wheel = wheel.size

        (0...slots_in_wheel).each do |i|
          slot_index = (current_slot_index + i) % slots_in_wheel
          slot = wheel[slot_index]
          next if slot.empty?

          slot.each do |timer|
            min_time = timer.expiration if min_time.nil? || timer.expiration < min_time
          end

          # If we found a timer in this slot, we don't need to check further slots in this wheel
          break unless slot.empty?
        end
      end

      min_time
    end

    private def process_expired_internal
      now_ms = Time.monotonic.total_milliseconds.to_u64
      if @current_time == 0
        @current_time = now_ms
      end
      advance_by = now_ms - @current_time
      advance_internal(advance_by.milliseconds) if advance_by > 0
    end

    private def calculate_next_sleep_duration_internal : Time::Span
      if next_expiration = next_expiration_time_internal
        now = @current_time
        if next_expiration > now
          return (next_expiration - now).milliseconds
        else
          # Timer is already due, wake up very soon
          return 1.millisecond
        end
      end
      # Default sleep if no timers
      100.milliseconds
    end

    # The main loop for the background processing fiber.
    private def process_timers_loop
      while @running
        sleep_duration = @mutex.synchronize do
          break unless @running
          process_expired_internal
          calculate_next_sleep_duration_internal
        end
        break unless sleep_duration
        sleep sleep_duration
      end
    end
  end
end
