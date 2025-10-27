module CML
  # Hierarchical timing wheel for efficient timeout management
  class TimerWheel
    getter current_time : UInt64
    getter? running : Bool = true

    record TimerEntry,
      id : UInt64,
      callback : Proc(Nil),
      expiration : UInt64,
      interval : UInt64? = nil

    getter wheel_config : Array(Tuple(Int32, Int32))

    def initialize(
      @tick_duration : Time::Span = 1.millisecond,
      @wheel_config : Array(Tuple(Int32, Int32)) = [
        {256, 8}, # Level 0: 256 slots, 8 bits
        {64, 6},  # Level 1: 64 slots, 6 bits
        {64, 6},  # Level 2: 64 slots, 6 bits
        {64, 6},  # Level 3: 64 slots, 6 bits
      ],
    )
      @current_time = 0_u64
      @wheel_slots = [] of Array(Array(TimerEntry))
      @wheel_offsets = [] of UInt64
      @wheel_masks = [] of UInt64
      @wheel_shifts = [] of Int32
      @pending_timers = [] of TimerEntry
      @next_id = 0_u64
      @mutex = Mutex.new

      setup_wheels
    end

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

    # Schedules a one-time timeout
    def schedule(timeout : Time::Span, &callback : ->) : UInt64
      add_timer(timeout, nil, callback)
    end

    # Schedules a recurring timer
    def schedule_interval(interval : Time::Span, &callback : ->) : UInt64
      add_timer(interval, interval, callback)
    end

    # Cancels a scheduled timer
    def cancel(timer_id : UInt64) : Bool
      @mutex.synchronize do
        @wheel_slots.each do |wheel|
          wheel.each do |slot|
            slot.reject! { |entry| entry.id == timer_id }
          end
        end
        @pending_timers.reject! { |entry| entry.id == timer_id }
      end
      true
    rescue
      false
    end

    # Advances the timer wheel by the given duration
    def advance(by time : Time::Span) : Nil
      ticks = (time / @tick_duration).to_i.to_u64
      return if ticks == 0

      @mutex.synchronize do
        end_time = @current_time + ticks
        while @current_time < end_time
          @current_time += 1
          process_current_tick
        end
      end
    end

    # Processes all expired timers
    def process_expired : Nil
      now_ms = Time.monotonic.total_milliseconds.to_u64
      advance_by = now_ms - @current_time
      advance(advance_by.milliseconds) if advance_by > 0
    end

    # Stops the timer wheel
    def stop : Nil
      @mutex.synchronize do
        @running = false
        @wheel_slots.each(&.clear)
        @pending_timers.clear
      end
    end

    private def add_timer(timeout : Time::Span, interval : Time::Span?, callback : ->) : UInt64
      timeout_ticks = (timeout / @tick_duration).to_i.to_u64
      raise ArgumentError.new("Timeout must be positive") if timeout_ticks == 0

      expiration = @current_time + timeout_ticks
      interval_ticks = interval ? (interval / @tick_duration).to_i.to_u64 : nil

      @mutex.synchronize do
        timer_id = @next_id
        @next_id += 1

        entry = TimerEntry.new(
          id: timer_id,
          callback: callback,
          expiration: expiration,
          interval: interval_ticks
        )

        if add_to_wheel(entry)
          timer_id
        else
          @pending_timers << entry
          timer_id
        end
      end
    end

    private def add_to_wheel(entry : TimerEntry) : Bool
      expiration = entry.expiration
      return false if expiration < @current_time

      delta = expiration - @current_time

      @wheel_config.each_with_index do |(slots, bits), level|
        max_ticks = 1_u64 << @wheel_shifts[Math.min(level + 1, @wheel_config.size - 1)]

        if delta < max_ticks
          shift = @wheel_shifts[level]
          mask = @wheel_masks[level]
          slot_index = ((expiration >> shift) & mask).to_i

          @wheel_slots[level][slot_index] << entry
          return true
        end
      end

      false
    end

    private def process_current_tick : Nil
      # Process level 0 (highest precision)
      level0_mask = @wheel_masks[0]
      slot_index0 = (@current_time & level0_mask).to_i
      process_slot(0, slot_index0)

      # Cascade timers from higher levels
      (1...@wheel_config.size).each do |level|
        level_mask = @wheel_masks[level]
        level_shift = @wheel_shifts[level]

        # Check if we've reached a boundary where we need to cascade
        if (@current_time & ((1_u64 << level_shift) - 1)) == 0
          slot_index = ((@current_time >> level_shift) & level_mask).to_i
          cascade_timers(level, slot_index)
        else
          break
        end
      end

      # Retry pending timers
      retry_pending_timers
    end

    private def process_slot(level : Int32, slot_index : Int32) : Nil
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
          # Handle callback errors gracefully without crashing
          # In production, you might want to log this
        end

        # Reschedule if it's an interval timer
        if interval = entry.interval
          new_entry = TimerEntry.new(
            id: entry.id,
            callback: entry.callback,
            expiration: @current_time + interval,
            interval: interval
          )
          add_to_wheel(new_entry) || @pending_timers << new_entry
        end
      end
    end

    private def cascade_timers(level : Int32, slot_index : Int32) : Nil
      slot = @wheel_slots[level][slot_index]
      return if slot.empty?

      @wheel_slots[level][slot_index] = [] of TimerEntry

      slot.each do |entry|
        add_to_wheel(entry) || @pending_timers << entry
      end
    end

    private def retry_pending_timers : Nil
      return if @pending_timers.empty?

      remaining = [] of TimerEntry

      @pending_timers.each do |entry|
        add_to_wheel(entry) || remaining << entry
      end

      @pending_timers = remaining
    end

    # Returns statistics about the timer wheel
    def stats : Hash(Symbol, Int32 | Array(Int32))
      @mutex.synchronize do
        total_timers = @pending_timers.size
        wheel_counts = @wheel_slots.map { |wheel| wheel.sum(&.size) }

        {
          pending:      total_timers,
          wheel_levels: wheel_counts,
          current_time: @current_time.to_i,
        }.to_h
      end
    end

    # Add a method to get the next expiration time (useful for optimization)
    def next_expiration_time : UInt64?
      @mutex.synchronize do
        min_time = nil

        # Check pending timers
        @pending_timers.each do |timer|
          min_time = timer.expiration if min_time.nil? || timer.expiration < min_time
        end

        # Check wheel slots
        @wheel_slots.each_with_index do |wheel, _|
          wheel.each_with_index do |slot, _|
            next if slot.empty?

            slot.each do |timer|
              min_time = timer.expiration if min_time.nil? || timer.expiration < min_time
            end
          end
        end

        min_time
      end
    end

    # Add a method to get the current time in a more usable format
    def current_time_ms : UInt64
      @current_time
    end

    # Get the tick duration for external use
    def tick_duration : Time::Span
      @tick_duration
    end
  end
end
