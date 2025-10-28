# CML Tracing Macro
#
# Usage:
#   CML.trace "msg", arg1, arg2
#
# When compiled with -Dtrace, expands to CML::Tracer.log(...)
# Otherwise, expands to nothing (zero overhead).

module CML
  macro trace(msg, *args, tag = nil)
    {% if flag?(:trace) %}
      CML::Tracer.log({{msg}}, {{args.splat}}, tag: {{tag}})
    {% end %}
  end
end

# Tracer with unique event IDs, fiber context, and outcome tracing
module CML
  module Tracer
    @@mutex = Mutex.new
    @@event_counter = Atomic(Int64).new(0)
    @@fiber_names = {} of Fiber => String
    @@output : IO = STDOUT
    @@filter_tags : Set(String)? = nil
    @@filter_events : Set(String)? = nil
    @@filter_fibers : Set(String)? = nil

    def self.next_event_id : Int64
      @@event_counter.add(1)
    end

    def self.fiber_id : String
      fiber = Fiber.current
      @@fiber_names[fiber]? || fiber.object_id.to_s
    end

    def self.fiber_name=(name : String)
      @@fiber_names[Fiber.current] = name
    end

    def self.log(msg, *args, tag : String? = nil)
      # Filtering logic
      if tag && @@filter_tags && !@@filter_tags.try(&.includes?(tag))
        return
      end
      if @@filter_events && !@@filter_events.try(&.includes?(msg))
        return
      end
      fiber = fiber_id
      if @@filter_fibers && !@@filter_fibers.try(&.includes?(fiber))
        return
      end
      @@mutex.synchronize do
        ts = Time.local.to_s("%H:%M:%S.%L")
        tag_str = tag ? "[tag=#{tag}]" : ""
        @@output.puts "[TRACE][#{ts}][fiber=#{fiber}]#{tag_str} #{msg} #{args.map(&.inspect).join(" ")}"
      end
    end

    def self.output=(io : IO)
      @@output = io
    end

    def self.filter_tags=(tags : Enumerable(String)?)
      @@filter_tags = tags ? tags.to_set : nil
    end

    def self.filter_events=(events : Enumerable(String)?)
      @@filter_events = events ? events.to_set : nil
    end

    def self.filter_fibers=(fibers : Enumerable(String)?)
      @@filter_fibers = fibers ? fibers.to_set : nil
    end
  end
end
