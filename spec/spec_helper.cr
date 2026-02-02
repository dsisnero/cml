require "spec"
require "../src/cml"

# Time compatibility for specs
module SpecTime
  {% if compare_versions(Crystal::VERSION, "1.19.0") >= 0 %}
    @@baseline_instant = Time.instant
  {% end %}

  # Returns monotonic time as Time::Span (compatible with Crystal <1.19 and >=1.19)
  def self.monotonic : Time::Span
    {% if compare_versions(Crystal::VERSION, "1.19.0") >= 0 %}
      # Crystal 1.19.0+: Use Time::Instant, return elapsed since baseline
      Time.instant - @@baseline_instant
    {% else %}
      # Pre-1.19.0: Use Time.monotonic
      Time.monotonic
    {% end %}
  end
end
