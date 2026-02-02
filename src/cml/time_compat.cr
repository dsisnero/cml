# Time compatibility helpers for Crystal 1.19+ with Time::Instant
#
# Provides version-aware monotonic time access to replace deprecated
# Time.monotonic usage while maintaining backward compatibility.

module CML
  {% if compare_versions(Crystal::VERSION, "1.19.0") >= 0 %}
    @@monotonic_baseline_instant : Time::Instant?
    @@monotonic_baseline_ms : UInt64 = 0_u64
  {% end %}

  # Returns monotonic milliseconds as UInt64.
  # Uses Time::Instant on Crystal >= 1.19.0, falls back to Time.monotonic on older versions.
  def self.monotonic_milliseconds : UInt64
    {% if compare_versions(Crystal::VERSION, "1.19.0") >= 0 %}
      # Crystal 1.19.0+: Use Time::Instant with baseline for monotonic milliseconds
      # Since Time::Instant doesn't expose raw values, we compute offset from a baseline
      baseline = @@monotonic_baseline_instant
      if baseline.nil?
        baseline = Time.instant
        @@monotonic_baseline_instant = baseline
      end
      baseline_ms = @@monotonic_baseline_ms
      elapsed = Time.instant - baseline
      baseline_ms + elapsed.total_milliseconds.to_u64
    {% else %}
      # Pre-1.19.0: Use deprecated Time.monotonic
      Time.monotonic.total_milliseconds.to_u64
    {% end %}
  end

  # Returns monotonic seconds as Float64.
  # Uses Time::Instant on Crystal >= 1.19.0, falls back to Time.monotonic on older versions.
  def self.monotonic_seconds : Float64
    monotonic_milliseconds / 1000.0
  end

  # Returns a monotonic time span for the given milliseconds.
  # Uses Time::Instant on Crystal >= 1.19.0, falls back to Time.monotonic on older versions.
  private def self.monotonic_span(milliseconds : UInt64) : Time::Span
    milliseconds.milliseconds
  end
end
