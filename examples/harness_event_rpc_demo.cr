#!/usr/bin/env crystal
# CML Event-Based RPC — Section 3.2
#
# Demonstrates the event-based remote procedure call pattern from:
#   "Prototyping Application Models in Concurrent ML"
#   Johnston, Fleury, Downton (2003)
#
# Key insight: rpc_client returns an *event*, not a value.
# The caller must sync on the event to get the result.
# This enables composing RPC calls with choose, guard, etc.

require "../src/cml"

# ==========
# Basic RPC: square computation service
# ==========
puts "=== Event-Based RPC (Section 3.2) ==="
puts

# rpc_client returns an Event(Int32) — must sync to get the value
square = ->(x : Int32) : Int32 { x * x }
evt = CML::Harness.rpc_client(square, 12)

puts "rpc_client(square, 12) returned an event: #{evt.class}"
puts "The server is running in a spawned fiber..."
puts "  -> rpc_server applies square(12) = 144"
puts "  -> sends 144 on a fresh channel"
puts "  -> rpc_client returns recv_evt(ch) — an event that will yield 144"

result = CML.sync(evt)
puts "CML.sync(evt) => #{result}"
puts

# ==========
# Multiple concurrent RPCs
# ==========
puts "=== Multiple Concurrent RPCs ==="

evt1 = CML::Harness.rpc_client(square, 5)
evt2 = CML::Harness.rpc_client(square, 10)
evt3 = CML::Harness.rpc_client(square, 15)

# Each event has its own spawned server fiber — they run concurrently
r1 = CML.sync(evt1)
r2 = CML.sync(evt2)
r3 = CML.sync(evt3)

puts "square(5) = #{r1}"
puts "square(10) = #{r2}"
puts "square(15) = #{r3}"
puts

# ==========
# Composing RPC with choose (first to complete wins)
# ==========
puts "=== Composing RPC with choose ==="

# Simulate varying computation times
tagger = ->(x : Int32) : String {
  sleep (x % 3).milliseconds
  "Result-#{x}"
}

evt_a = CML::Harness.rpc_client(tagger, 3)
evt_b = CML::Harness.rpc_client(tagger, 1)

# choose picks whichever event fires first
chosen = CML.sync(CML.choose(evt_a, evt_b))
puts "CML.choose(evt_a, evt_b) selected: #{chosen}"
puts "  (tagger(1) was faster, so it wins)"
puts

# ==========
# Composing RPC with timeout
# ==========
puts "=== RPC with Timeout ==="

slow = ->(x : Int32) : Int32 {
  sleep 100.milliseconds
  x * 2
}

evt_slow = CML::Harness.rpc_client(slow, 21)
result = CML.sync(CML.choose(evt_slow, CML::Harness.timeout_evt(5.milliseconds)))
puts "RPC with 5ms timeout: #{result.inspect}"
puts "  (should be nil — timeout fired before RPC completed)"
puts

# ==========
# RPC server directly (Section 3.2 lower half)
# ==========
puts "=== Direct rpc_server Usage ==="
puts "rpc_server directly applies function and sends on channel:"

ch = CML::Chan(String).new
greet = ->(name : String) : String { "Hello, #{name}!" }

CML.spawn do
  CML::Harness.rpc_server(ch, greet, "World")
end

Fiber.yield
puts "ch.recv => #{ch.recv}"
puts

puts "Done!"
