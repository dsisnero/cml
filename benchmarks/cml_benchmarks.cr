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
  choice = CML.choose([CML.always(1), CML.never(Int32)])
  x.report("choose(Always, Never)") { CML.sync(choice) }
end

# =================================================================
# Benchmark 4: Channel Creation Overhead
#
# Measures the cost of creating a new channel object.
# Channels are frequently created for RPC patterns.
# =================================================================
puts "\n--- Benchmark: Channel Creation ---"
Benchmark.ips do |x|
  x.report("Chan.new") { CML::Chan(Int32).new }
end

# =================================================================
# Benchmark 5: Channel Rendezvous (Two Fibers, pre-created channel)
#
# Measures the cost of passing a value from one fiber to another
# via an already-created channel. This is the most common pattern.
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
    case status = CML.timeout(1.seconds).poll
    when CML::Blocked(Nil)
      tid = CML::TransactionId.new
      status.block_fn.call(tid, -> { })
      tid.try_cancel
    else
      raise "expected timeout poll to block before scheduling"
    end
  end
end
