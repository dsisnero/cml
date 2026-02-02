module CML
  # Hierarchical timing wheel for efficient timeout management.
  # This class is thread-safe.
  class TimerWheel
    getter current_time : UInt64
    getter? running : Bool

    # Represents a scheduled timer.
    class TimerEntry
      getter id : UInt64
      getter callback : Proc(Nil)
      getter expiration : UInt64
      getter interval : UInt64?
      getter? cancelled : Bool

      def initialize(@id, @callback, @expiration, @interval)
        @cancelled = false
      end

      def cancel!
        @cancelled = true
      end
    end

    getter wheel_config : Array(Tuple(Int32, Int32))
    @sync_callbacks : Bool = false

    def initialize(
      @tick_duration : Time::Span = 1.millisecond,
      @wheel_config : Array(Tuple(Int32, Int32)) = [
        {256, 8},
        {64, 6},
        {64, 6},
        {64, 6},
      ],
      auto_advance : Bool = true,
      sync_callbacks : Bool = false,
    )
      @current_time = 0_u64
      @wheel_slots = Array(Array(Array(TimerEntry))).new
      @wheel_offsets = Array(UInt64).new
      @wheel_masks = Array(UInt64).new
      @wheel_shifts = Array(Int32).new
      @pending_timers = Array(TimerEntry).new
      @next_id = 0_u64
      @timer_locations = Hash(UInt64, TimerEntry).new
      @mutex = Sync::Mutex.new
      @running = true
      @sync_callbacks = sync_callbacks

      setup_wheels
      spawn { process_timers_loop } if auto_advance
    end

    # Schedules a one-time timeout.
    def schedule(timeout : Time::Span, &callback : -> Nil) : UInt64
      @mutex.synchronize do
        add_timer_internal(timeout, nil, callback)
      end
    end

    # Schedules a recurring timer.
    def schedule_interval(interval : Time::Span, &callback : -> Nil) : UInt64
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

    def tick_duration : Time::Span
      @tick_duration
    end

    private def setup_wheels
      total_shift = 0
      @wheel_config.each_with_index do |(slots, bits), level|
        @wheel_slots << Array(Array(TimerEntry)).new(slots) { Array(TimerEntry).new }
        @wheel_masks << (slots - 1).to_u64
        @wheel_shifts << total_shift
        @wheel_offsets << (level == 0 ? 0_u64 : 1_u64 << total_shift)
        total_shift += bits
      end
    end

    private def add_timer_internal(timeout : Time::Span, interval : Time::Span?, callback : -> Nil) : UInt64
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
      @timer_locations[timer_id] = entry
      timer_id
    end

    private def cancel_internal(timer_id : UInt64) : Bool
      if entry = @timer_locations.delete(timer_id)
        entry.cancel!
        true
      else
        false
      end
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
      @timer_locations.clear
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

      expired = Array(TimerEntry).new
      remaining = Array(TimerEntry).new

      slot.each do |entry|
        next if entry.cancelled?

        if entry.expiration <= @current_time
          expired << entry
        else
          remaining << entry
        end
      end

      @wheel_slots[level][slot_index] = remaining

      expired.each do |entry|
        next if entry.cancelled?

        if @sync_callbacks
          entry.callback.call
        else
          spawn { entry.callback.call rescue nil }
        end

        if interval = entry.interval
          new_entry = TimerEntry.new(
            id: entry.id,
            callback: entry.callback,
            expiration: @current_time + interval,
            interval: interval
          )
          if add_to_wheel_internal(new_entry)
            @timer_locations[entry.id] = new_entry
          else
            @pending_timers << new_entry
          end
        else
          @timer_locations.delete(entry.id)
        end
      end
    end

    private def cascade_timers_internal(level : Int32, slot_index : Int32)
      slot = @wheel_slots[level][slot_index]
      return if slot.empty?

      @wheel_slots[level][slot_index] = Array(TimerEntry).new
      slot.each do |entry|
        next if entry.cancelled?
        add_to_wheel_internal(entry) || @pending_timers << entry
      end
    end

    private def retry_pending_timers_internal
      return if @pending_timers.empty?
      remaining = Array(TimerEntry).new
      @pending_timers.each do |entry|
        add_to_wheel_internal(entry) || remaining << entry
      end
      @pending_timers = remaining
    end

    private def next_expiration_time_internal : UInt64?
      min_time = nil

      @pending_timers.each do |timer|
        min_time = timer.expiration if min_time.nil? || timer.expiration < min_time
      end

      @wheel_slots.each_with_index do |wheel, level|
        current_slot_index = ((@current_time >> @wheel_shifts[level]) & @wheel_masks[level]).to_i
        slots_in_wheel = wheel.size

        (0...slots_in_wheel).each do |i|
          slot_index = (current_slot_index + i) % slots_in_wheel
          slot = wheel[slot_index]
          next if slot.empty?

          slot.each do |timer|
            min_time = timer.expiration if min_time.nil? || timer.expiration < min_time
          end

          break unless slot.empty?
        end
      end

      min_time
    end

    private def process_expired_internal
      now_ms = CML.monotonic_milliseconds
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
          return 1.millisecond
        end
      end
      100.milliseconds
    end

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
