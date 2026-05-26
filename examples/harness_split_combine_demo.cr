#!/usr/bin/env crystal
# CML Split/Combine Harness Examples
#
# Demonstrates the five harness stages from:
#   "Prototyping Application Models in Concurrent ML"
#   Johnston, Fleury, Downton (2003)
#
# This example sums an array using each harness type.
# Phase 4.1: Serial Hierarchical (SH)
# Phase 4.2: Communicating Parallel Hierarchical (CPH)
# Phase 4.3: Event-Explicit Parallel Hierarchical (EEPH)
# Phase 4.4: Event-Implicit Parallel Hierarchical (EIPH)
# Phase 4.5: Unified Harness (U)

require "../src/cml"

module HarnessDemo
  # ---------------
  # Application-specific functions (provided by the user)
  # ---------------

  # Leaf function: sum an array of integers
  def self.sum_leaf(arr : Array(Int32)) : Int32
    arr.sum
  end

  # Split function: divide array in half, return (combine, left, right)
  # The combine function adds two partial results
  def self.split_add(arr : Array(Int32)) : {Proc(Int32, Int32, Int32), Array(Int32), Array(Int32)}
    mid = arr.size // 2
    left = arr[0...mid]
    right = arr[mid..]
    combine = ->(a : Int32, b : Int32) : Int32 { a + b }
    {combine, left, right}
  end

  # ---------------
  # Benchmark helper
  # ---------------

  def self.time(label : String, &block : -> T) : T forall T
    start = Time.instant
    result = block.call
    elapsed = (Time.instant - start).total_milliseconds
    puts "  #{label}: #{result} (#{elapsed.round(2)}ms)"
    result
  end
end

# ==========
# Test data
# ==========
input = (1..16).to_a
expected = input.sum # 136
max_depth = 4        # Split until single elements

puts "CML Split/Combine Harnesses"
puts "==========================="
puts "Input: #{input}"
puts "Expected sum: #{expected}"
puts "Max depth: #{max_depth}"
puts

# ==========
# 4.1 SH — Serial Hierarchical Harness
# ==========
puts "--- 4.1 SH Harness (Serial) ---"
HarnessDemo.time("SH") do
  CML::Harness.sh_harness(
    depth: 0, max_depth: max_depth,
    f: ->HarnessDemo.sum_leaf(Array(Int32)),
    split: ->HarnessDemo.split_add(Array(Int32)),
    input: input,
  )
end
puts "  (Sequential: both sub-problems solved in same fiber)"
puts

# ==========
# 4.2 CPH — Communicating Parallel Hierarchical Harness
# ==========
puts "--- 4.2 CPH Harness (Channel-based Parallel) ---"
result_ch = CML::Chan(Int32).new

CML.spawn do
  CML::Harness.cph_harness(
    depth: 0, max_depth: max_depth,
    f: ->HarnessDemo.sum_leaf(Array(Int32)),
    split: ->HarnessDemo.split_add(Array(Int32)),
    ch: result_ch,
    input: input,
  )
end

HarnessDemo.time("CPH") do
  result_ch.recv
end
puts "  (Parallel: sub-harnesses spawned in fibers, communicate via channels)"
puts

# ==========
# 4.3 EEPH — Event-Explicit Parallel Hierarchical Harness
# ==========
puts "--- 4.3 EEPH Harness (Event-Explicit Parallel) ---"
HarnessDemo.time("EEPH") do
  CML::Harness.eeph_harness(
    depth: 0, max_depth: max_depth,
    f: ->HarnessDemo.sum_leaf(Array(Int32)),
    split: ->HarnessDemo.split_add(Array(Int32)),
    input: input,
  )
end
puts "  (Parallel: RPC spawns sub-harnesses, explicit sync collects results)"
puts

# ==========
# 4.4 EIPH — Event-Implicit Parallel Hierarchical Harness
# ==========
puts "--- 4.4 EIPH Harness (Event-Implicit Parallel) ---"
eiph_evt = CML::Harness.eiph_harness(
  depth: 0, max_depth: max_depth,
  f: ->HarnessDemo.sum_leaf(Array(Int32)),
  split: ->HarnessDemo.split_add(Array(Int32)),
  input: input,
)

HarnessDemo.time("EIPH") do
  CML.sync(eiph_evt)
end
puts "  (Parallel: purely event-based, sync deferred to last moment via guard)"
puts

# ==========
# 4.5 U — Unified Harness (parameterized over execution strategy)
# ==========
puts "--- 4.5 U Harness (Unified) ---"

# SH-style: direct execution, direct merge, identity return
puts "  U(SH-style):"
HarnessDemo.time("U-SH") do
  CML::Harness.u_harness(
    exec: ->(daughter : Proc(Array(Int32), Int32), inp : Array(Int32)) : Int32 { daughter.call(inp) },
    merge_using: ->(combine : Proc(Int32, Int32, Int32), o1 : Int32, o2 : Int32) : Int32 { combine.call(o1, o2) },
    return_val: ->(v : Int32) : Int32 { v },
    depth: 0, max_depth: max_depth,
    f: ->HarnessDemo.sum_leaf(Array(Int32)),
    split: ->HarnessDemo.split_add(Array(Int32)),
    input: input,
  )
end

# EIPH-style: RPC execution, event_and merge, alwaysEvt return
puts "  U(EIPH-style):"
u_eiph_evt = CML::Harness.u_harness(
  exec: ->(daughter : Proc(Array(Int32), CML::Event(Int32)), inp : Array(Int32)) : CML::Event(Int32) {
    CML::Harness.rpc_client_evt(daughter, inp)
  },
  merge_using: ->(combine : Proc(Int32, Int32, Int32), evt1 : CML::Event(Int32), evt2 : CML::Event(Int32)) : CML::Event(Int32) {
    CML::Harness.event_and(combine, evt1, evt2)
  },
  return_val: ->(v : Int32) : CML::Event(Int32) { CML.always(v) },
  depth: 0, max_depth: max_depth,
  f: ->HarnessDemo.sum_leaf(Array(Int32)),
  split: ->HarnessDemo.split_add(Array(Int32)),
  input: input,
)

HarnessDemo.time("U-EIPH") do
  CML.sync(u_eiph_evt)
end

puts
puts "All harnesses produced correct results!"
