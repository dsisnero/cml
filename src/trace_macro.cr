# trace_macro.cr - Zero-overhead tracing system for CML
#
# This module provides macro-based tracing with conditional compilation.
# When compiled with `-Dtrace`, trace statements execute and can be filtered
# by tag, event type, or fiber. When compiled without `-Dtrace`, all trace
# statements are completely removed (zero runtime overhead).
#
# Based on the debugging guide documentation and SML/NJ TRACE_CML signature,
# but simplified for Crystal idioms and macro capabilities.

{% if flag?(:trace) %}
  require "tracing"
{% end %}

module CML
  # Tracer configuration class for runtime filtering and output control.
  # All methods are no-ops when compiled without `-Dtrace`.
  class Tracer
    @@output : IO = STDOUT
    @@mutex = CML::Sync::Mutex.new(:reentrant)

    # Filter sets (thread-safe via mutex)
    @@filter_tags = Set(String).new
    @@filter_events = Set(String).new
    @@filter_fibers = Set(String).new

    # Fiber name mapping
    @@fiber_names = Hash(Fiber, String).new
    @@backend_configured = Atomic(Bool).new(false)

    # Event counter for unique IDs
    @@event_counter = Atomic(Int64).new(0_i64)

    # Set the output destination for trace messages
    def self.set_output(io : IO) : Nil
      {% if flag?(:trace) %}
        @@mutex.synchronize do
          @@output = io
        end
      {% end %}
    end

    # Set filter tags - only traces with these tags will be shown
    def self.set_filter_tags(tags : Enumerable(String)) : Nil
      {% if flag?(:trace) %}
        @@mutex.synchronize do
          @@filter_tags.clear
          tags.each { |tag| @@filter_tags.add(tag) }
        end
      {% end %}
    end

    # Set filter events - only traces with these event types will be shown
    def self.set_filter_events(events : Enumerable(String)) : Nil
      {% if flag?(:trace) %}
        @@mutex.synchronize do
          @@filter_events.clear
          events.each { |event| @@filter_events.add(event) }
        end
      {% end %}
    end

    # Set filter fibers - only traces from these fibers will be shown
    def self.set_filter_fibers(fibers : Enumerable(String)) : Nil
      {% if flag?(:trace) %}
        @@mutex.synchronize do
          @@filter_fibers.clear
          fibers.each { |fiber| @@filter_fibers.add(fiber) }
        end
      {% end %}
    end

    # Set a name for the current fiber (for filtering)
    def self.set_fiber_name(name : String) : Nil
      {% if flag?(:trace) %}
        @@mutex.synchronize do
          @@fiber_names[Fiber.current] = name
        end
      {% end %}
    end

    # Get the name of a fiber (or its ID if no name set)
    private def self.fiber_name(fiber : Fiber = Fiber.current) : String
      @@mutex.synchronize do
        @@fiber_names[fiber]? || fiber.object_id.to_s
      end
    end

    # Check if a trace should be output based on filters
    private def self.should_trace?(event_type : String, tag : String?) : Bool
      # If any filter is empty, it means "accept all"
      tag_match = @@filter_tags.empty? || (tag ? @@filter_tags.includes?(tag) : false)
      event_match = @@filter_events.empty? || @@filter_events.includes?(event_type)
      fiber_match = @@filter_fibers.empty? || @@filter_fibers.includes?(fiber_name)

      tag_match && event_match && fiber_match
    end

    # Generate a unique event ID
    private def self.next_event_id : Int64
      @@event_counter.add(1)
    end

    # Emit a structured tracing.cr event. The mutex serializes CML trace output
    # and protects all CML filter state in parallel execution contexts.
    def self.trace_impl(event_type : String, *args, tag : String? = nil) : Nil
      {% if flag?(:trace) %}
        @@mutex.synchronize do
          return unless should_trace?(event_type, tag)

          configure_backend
          ::Tracing.debug(
            event_type,
            tag: tag || "cml",
            fiber: fiber_name,
            arguments: args.map(&.inspect).join(", "),
          )
        end
      {% end %}
    end

    {% if flag?(:trace) %}
      private def self.configure_backend : Nil
        return unless @@backend_configured.compare_and_set(false, true)

        # Leave an application-configured tracing subscriber untouched.
        ::Tracing::Subscriber.try_init(
          ::Tracing::Registry.default
            .with(::Tracing::FmtLayer.make_writer { @@output }.compact)
        )
      end
    {% end %}
  end

  # Main tracing macro
  # Usage: CML.trace "event_type", arg1, arg2, ..., tag: "optional_tag"
  macro trace(event_type, *args, tag = nil)
    {% if flag?(:trace) %}
      # When tracing is enabled, expand to runtime check and output.
      # Use the runtime string value of event_type so filtering works with
      # ordinary string names instead of quoted source text.
      {% if args.size > 0 %}
        ::CML::Tracer.trace_impl(({{ event_type }}).to_s, {{ args.splat }}{% if tag %}, tag: {{ tag }}{% end %})
      {% else %}
        ::CML::Tracer.trace_impl(({{ event_type }}).to_s{% if tag %}, tag: {{ tag }}{% end %})
      {% end %}
    {% else %}
      # When tracing is disabled, expand to nothing (zero overhead)
      # This nil ensures the expression is syntactically valid but does nothing
      nil
    {% end %}
  end
end
