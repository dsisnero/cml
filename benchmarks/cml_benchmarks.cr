require "benchmark"
require "../src/cml"

# =================================================================
# Benchmark 1: Event Creation Overhead
#
# Measures the cost of creating different types of event objects.
# This helps identify any expensive constructors.
# =================================================================
puts "--- Benchmark: Event Creation Overhead ---"
Benchmark.ips do |x|
  ch = CML::Chan(Int32).new
  x.report("AlwaysEvt") { CML.always(1) }
  x.report("NeverEvt") { CML.never }
  x.report("TimeoutEvt") { CML.timeout(1.seconds) }
  x.report("SendEvt") { ch.send_evt(1) }
  x.report("RecvEvt") { ch.recv_evt }
  x.report("WrapEvt") { CML.wrap(CML.always(1)) { |v| v + 1 } }
  x.report("GuardEvt") { CML.guard { CML.always(1) } }
end

# =================================================================
# Benchmark 2: Sync on AlwaysEvt
#
# Measures the best-case scenario for synchronization: an event
# that is immediately ready. This is the baseline for the CML
# scheduler's overhead.
# =================================================================
puts "\n--- Benchmark: Sync on AlwaysEvt ---"
Benchmark.ips do |x|
  always_evt = CML.always(1)
  x.report("sync(AlwaysEvt)") { CML.sync(always_evt) }
end

# =================================================================
# Benchmark 3: Choose between two AlwaysEvt
#
# Measures the overhead of the `choose` combinator when one of
# the events is an immediate winner. The polling optimization
# should make this very fast.
# =================================================================
puts "\n--- Benchmark: Choose with AlwaysEvt ---"
Benchmark.ips do |x|
  choice = CML.choose(CML.always(1), CML.never(Int32))
  x.report("choose(Always, Never)") { CML.sync(choice) }
end

# =================================================================
# Benchmark 4: Channel Rendezvous (Single Fiber)
#
# Measures the cost of a simple send/receive rendezvous.
# This is not a typical use case (usually done between fibers)
# but it isolates the cost of channel mechanics.
# =================================================================
puts "\n--- Benchmark: Channel Rendezvous (Single Fiber) ---"
Benchmark.ips do |x|
  ch = CML::Chan(Int32).new
  send_evt = ch.send_evt(42)
  recv_evt = ch.recv_evt

  x.report("rendezvous") do
    # In a single fiber, we need to use a guard to defer one of the ops.
    # We also wrap the events to have a common return type for `choose`.
    choice = CML.choose(
      CML.wrap(send_evt) { |_| :sent },
      CML.guard { CML.wrap(recv_evt) { |_| :received } }
    )
    CML.sync(choice)
  end
end

# =================================================================
# Benchmark 5: Channel Rendezvous (Two Fibers)
#
# The most common channel use case: passing a value from one
# fiber to another. This measures the full cost of a synchronized
# handoff, including fiber scheduling.
# =================================================================
puts "\n--- Benchmark: Channel Rendezvous (Two Fibers) ---"
Benchmark.ips do |x|
  ch = CML::Chan(Int32).new
  x.report("rendezvous (2 fibers)") do
    spawn { CML.sync(ch.send_evt(1)) }
    CML.sync(ch.recv_evt)
  end
end

# =================================================================
# Benchmark 6: Timeout Creation and Cancellation
#
# Measures the cost of scheduling a timer with the TimerWheel
# and then immediately cancelling it. This is important for
# `choose` operations where timeouts are raced against other events.
# =================================================================
puts "\n--- Benchmark: Timeout Creation and Cancellation ---"
Benchmark.ips do |x|
  x.report("schedule+cancel") do
    pick = CML::Pick(Symbol).new
    cancel = CML.timeout(1.seconds).try_register(pick)
    cancel.call
  end
end
