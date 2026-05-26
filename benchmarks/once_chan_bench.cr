# benchmarks/once_chan_bench.cr
# Compare OnceChan vs standard Chan for RPC pattern
#
# rpc_client creates a new channel per call — this is the most common
# single-use channel pattern. OnceChan eliminates Deque allocation
# and cleanup overhead.

require "benchmark"
require "../src/cml"

puts "=" * 60
puts "OnceChan vs Chan: RPC Pattern Benchmark"
puts "=" * 60

ITERATIONS = 50_000

# Helper: measure ns/op
def measure(name : String, iterations : Int32, &block)
  # Warmup
  1_000.times { block.call } if iterations > 1_000

  start = Time.instant
  iterations.times { block.call }
  elapsed = Time.instant - start
  nanos = elapsed.total_nanoseconds / iterations
  ops = iterations / elapsed.total_seconds
  puts "  #{name}: #{nanos.round(2)} ns/op, #{ops.round(2).to_i} ops/s"
  nanos
end

puts
puts "--- RPC round-trip (channel create + send + recv) ---"
puts

# ============================================
# Standard Chan RPC
# ============================================
puts "Standard Chan:"
chan_ns = measure("Chan RPC", ITERATIONS) do
  ch = CML::Chan(Int32).new
  spawn { ch.send(42) }
  ch.recv
end

# ============================================
# OnceChan RPC
# ============================================
puts "OnceChan:"
once_ns = measure("OnceChan RPC", ITERATIONS) do
  ch = CML::OnceChan(Int32).new
  CML.spawn { ch.send(42) }
  ch.recv
end

speedup = chan_ns / once_ns
puts
puts "--- Result ---"
puts "  Chan:     #{chan_ns.round(2)} ns/op"
puts "  OnceChan: #{once_ns.round(2)} ns/op"
puts "  Speedup:  #{speedup.round(2)}x"
puts

# ============================================
# IPC-style: send in spawned fiber, recv in main
# (most common pattern: parent spawns child, child sends result)
# ============================================
puts "--- RPC with result computation (spawn child, compute, send back) ---"
puts

square = ->(x : Int32) : Int32 { x * x }

puts "Standard Chan:"
chan_ipc_ns = measure("Chan IPC", ITERATIONS) do
  ch = CML::Chan(Int32).new
  spawn do
    result = square.call(7)
    ch.send(result)
  end
  ch.recv
end

puts "OnceChan:"
once_ipc_ns = measure("OnceChan IPC", ITERATIONS) do
  ch = CML::OnceChan(Int32).new
  CML.spawn do
    result = square.call(7)
    ch.send(result)
  end
  ch.recv
end

speedup_ipc = chan_ipc_ns / once_ipc_ns
puts
puts "--- IPC Result ---"
puts "  Chan:     #{chan_ipc_ns.round(2)} ns/op"
puts "  OnceChan: #{once_ipc_ns.round(2)} ns/op"
puts "  Speedup:  #{speedup_ipc.round(2)}x"
