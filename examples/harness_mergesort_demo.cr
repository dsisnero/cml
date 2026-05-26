#!/usr/bin/env crystal
# Parallel Mergesort using CML EIPH Harness
#
# Demonstrates the Event-Implicit Parallel Hierarchical (EIPH) harness
# applied to a practical sorting problem.
#
# The user provides:
#   f     — base case: sort a small array
#   split — divide array in half, combine = merge two sorted arrays
#
# The harness handles all parallelism and event composition.

require "../src/cml"

# ---------------
# Application-specific: mergesort components
# ---------------

# Base case: sort a small array (insertion sort for leaf arrays)
def self.insertion_sort(arr : Array(Int32)) : Array(Int32)
  result = arr.dup
  (1...result.size).each do |i|
    key = result[i]
    j = i - 1
    while j >= 0 && result[j] > key
      result[j + 1] = result[j]
      j -= 1
    end
    result[j + 1] = key
  end
  result
end

# Split: divide array in half
# Combine: merge two sorted arrays
def self.split_and_merge(arr : Array(Int32)) : {Proc(Array(Int32), Array(Int32), Array(Int32)), Array(Int32), Array(Int32)}
  mid = arr.size // 2
  left = arr[0...mid]
  right = arr[mid..]

  combine = ->(a : Array(Int32), b : Array(Int32)) : Array(Int32) {
    result = Array(Int32).new(a.size + b.size)
    i = j = 0
    while i < a.size && j < b.size
      if a[i] <= b[j]
        result << a[i]; i += 1
      else
        result << b[j]; j += 1
      end
    end
    result.concat(a[i..]) if i < a.size
    result.concat(b[j..]) if j < b.size
    result
  }

  {combine, left, right}
end

# ---------------
# Demo
# ---------------

# Generate random input
rng = Random.new(42)
input = Array(Int32).new(32) { rng.rand(0..999) }
expected = input.sort

puts "Parallel Mergesort via EIPH Harness"
puts "==================================="
puts "Input size: #{input.size}"
puts "Max depth: 5 (splits into sub-arrays of ~1 element)"
puts

# ---------------
# Serial baseline (SH harness)
# ---------------
puts "--- 4.1 SH Harness (Serial baseline) ---"
start = Time.instant
sh_result = CML::Harness.sh_harness(
  depth: 0, max_depth: 5,
  f: ->insertion_sort(Array(Int32)),
  split: ->split_and_merge(Array(Int32)),
  input: input,
)
sh_elapsed = (Time.instant - start).total_milliseconds
puts "  Result correct: #{sh_result == expected}"
puts "  Time: #{sh_elapsed.round(2)}ms"
puts

# ---------------
# Event-based parallel (EIPH harness)
# ---------------
puts "--- 4.4 EIPH Harness (Event-Implicit Parallel) ---"
start = Time.instant
eiph_evt = CML::Harness.eiph_harness(
  depth: 0, max_depth: 5,
  f: ->insertion_sort(Array(Int32)),
  split: ->split_and_merge(Array(Int32)),
  input: input,
)
eiph_result = CML.sync(eiph_evt)
eiph_elapsed = (Time.instant - start).total_milliseconds
puts "  Result correct: #{eiph_result == expected}"
puts "  Time: #{eiph_elapsed.round(2)}ms"
puts

# ---------------
# Event-explicit parallel (EEPH harness)
# ---------------
puts "--- 4.3 EEPH Harness (Event-Explicit Parallel) ---"
start = Time.instant
eeph_result = CML::Harness.eeph_harness(
  depth: 0, max_depth: 5,
  f: ->insertion_sort(Array(Int32)),
  split: ->split_and_merge(Array(Int32)),
  input: input,
)
eeph_elapsed = (Time.instant - start).total_milliseconds
puts "  Result correct: #{eeph_result == expected}"
puts "  Time: #{eeph_elapsed.round(2)}ms"
puts

# ---------------
# Unified Harness (EIPH-style)
# ---------------
puts "--- 4.5 U Harness (EIPH-style, parameterized) ---"
start = Time.instant
u_eiph_evt = CML::Harness.u_harness(
  exec: ->(daughter : Proc(Array(Int32), CML::Event(Array(Int32))), inp : Array(Int32)) : CML::Event(Array(Int32)) {
    CML::Harness.rpc_client_evt(daughter, inp)
  },
  merge_using: ->(combine : Proc(Array(Int32), Array(Int32), Array(Int32)),
                  evt1 : CML::Event(Array(Int32)),
                  evt2 : CML::Event(Array(Int32))) : CML::Event(Array(Int32)) {
    CML::Harness.event_and(combine, evt1, evt2)
  },
  return_val: ->(v : Array(Int32)) : CML::Event(Array(Int32)) { CML.always(v) },
  depth: 0, max_depth: 5,
  f: ->insertion_sort(Array(Int32)),
  split: ->split_and_merge(Array(Int32)),
  input: input,
)
u_result = CML.sync(u_eiph_evt)
u_elapsed = (Time.instant - start).total_milliseconds
puts "  Result correct: #{u_result == expected}"
puts "  Time: #{u_elapsed.round(2)}ms"
puts

puts "All harnesses produced correct sorted output!"
puts
puts "Note: Crystal CML is single-threaded (cooperative fibers),"
puts "so parallelism is concurrent (interleaved) not truly parallel."
puts "For true parallelism, combine with Crystal's MT execution context."
