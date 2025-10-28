require "../src/cml"
require "../src/trace_macro"
require "benchmark"

puts "--- Benchmark: Macro Tracing Overhead ---"
Benchmark.ips do |x|
  x.report("no tracing macro") do
    # No tracing
    1 + 1
  end
  x.report("tracing macro (disabled)") do
    CML.trace "noop", 1, 2, 3
  end
end
