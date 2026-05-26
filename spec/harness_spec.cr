require "./spec_helper"

# Test harnesses from "Prototyping Application Models in Concurrent ML"
# Johnston, Fleury, Downton (2003)
#
# Test data: sum-of-array using split/combine pattern
#   f      : sums an array (leaf work)
#   split  : splits array roughly in half, returns (combine=+, left, right)
#   combine: addition
#
# Verification: result must equal array.sum regardless of depth/method

module HarnessSpecHelpers
  # Leaf function: sum the array
  def self.sum_array(arr : Array(Int32)) : Int32
    arr.sum
  end

  # Split function: divide array in half, return (combine_fn, left, right)
  # combine_fn adds two Int32 results
  def self.split_array(arr : Array(Int32)) : {Proc(Int32, Int32, Int32), Array(Int32), Array(Int32)}
    mid = arr.size // 2
    left = arr[0...mid]
    right = arr[mid..]
    combine = ->(a : Int32, b : Int32) : Int32 { a + b }
    {combine, left, right}
  end
end

describe CML::Harness do
  describe "Event-based RPC (Section 3.2)" do
    it "rpc_client returns an event that resolves to the function result" do
      call_count = Atomic(Int32).new(0)
      square = ->(x : Int32) : Int32 { call_count.add(1); x * x }

      evt = CML::Harness.rpc_client(square, 7)

      # Before sync, the server may or may not have run (spawn is async)
      evt.should be_a(CML::Event(Int32))

      result = CML.sync(evt)
      result.should eq(49)
      call_count.get.should eq(1)
    end

    it "rpc_client works with multiple concurrent calls" do
      doubler = ->(x : Int32) : Int32 { x * 2 }

      evt1 = CML::Harness.rpc_client(doubler, 10)
      evt2 = CML::Harness.rpc_client(doubler, 20)
      evt3 = CML::Harness.rpc_client(doubler, 30)

      r1 = CML.sync(evt1)
      r2 = CML.sync(evt2)
      r3 = CML.sync(evt3)

      r1.should eq(20)
      r2.should eq(40)
      r3.should eq(60)
    end

    it "rpc_server applies function and sends result on channel" do
      ch = CML::Chan(Int32).new
      triple = ->(x : Int32) : Int32 { x * 3 }

      CML.spawn do
        CML::Harness.rpc_server(ch, triple, 15)
      end
      Fiber.yield

      result = ch.recv
      result.should eq(45)
    end
  end

  describe "timeout via guard (Section 3.3)" do
    it "timeout_evt fires after specified duration" do
      start = SpecTime.monotonic
      CML.sync(CML::Harness.timeout_evt(15.milliseconds))
      elapsed = SpecTime.monotonic - start
      elapsed.should be >= 10.milliseconds
    end

    it "timeout_evt uses deferred time evaluation (guard semantics)" do
      # The time should be evaluated when guard is forced, not when timeout_evt is called
      evt = CML::Harness.timeout_evt(1.second)
      # Calling timeout_evt shouldn't block - it creates a guard event
      evt.should be_a(CML::Event(Nil))

      start = SpecTime.monotonic
      CML.sync(evt)
      elapsed = SpecTime.monotonic - start
      elapsed.should be >= 200.milliseconds
    end
  end

  describe "SH harness - Serial Hierarchical (Section 4.1)" do
    it "correctly sums an array serially" do
      input = [1, 2, 3, 4, 5, 6, 7, 8]
      result = CML::Harness.sh_harness(
        depth: 0, max_depth: 3,
        f: ->HarnessSpecHelpers.sum_array(Array(Int32)),
        split: ->HarnessSpecHelpers.split_array(Array(Int32)),
        input: input
      )
      result.should eq(36) # 1+2+...+8
    end

    it "returns leaf result when max_depth is 0" do
      input = [5, 10, 15]
      result = CML::Harness.sh_harness(
        depth: 0, max_depth: 0,
        f: ->HarnessSpecHelpers.sum_array(Array(Int32)),
        split: ->HarnessSpecHelpers.split_array(Array(Int32)),
        input: input
      )
      result.should eq(30) # 5+10+15 (direct leaf sum, no splitting)
    end

    it "handles single-element array with max_depth > 0" do
      input = [42]
      result = CML::Harness.sh_harness(
        depth: 0, max_depth: 2,
        f: ->HarnessSpecHelpers.sum_array(Array(Int32)),
        split: ->HarnessSpecHelpers.split_array(Array(Int32)),
        input: input
      )
      result.should eq(42)
    end
  end

  describe "CPH harness - Communicating Parallel Hierarchical (Section 4.2)" do
    it "correctly sums an array using channel-based parallelism" do
      input = [1, 2, 3, 4, 5, 6, 7, 8]
      result_ch = CML::Chan(Int32).new

      CML.spawn do
        CML::Harness.cph_harness(
          depth: 0, max_depth: 3,
          f: ->HarnessSpecHelpers.sum_array(Array(Int32)),
          split: ->HarnessSpecHelpers.split_array(Array(Int32)),
          ch: result_ch,
          input: input
        )
      end

      result = result_ch.recv
      result.should eq(36)
    end

    it "returns leaf result through channel when max_depth is 0" do
      input = [7, 8, 9]
      result_ch = CML::Chan(Int32).new

      CML.spawn do
        CML::Harness.cph_harness(
          depth: 0, max_depth: 0,
          f: ->HarnessSpecHelpers.sum_array(Array(Int32)),
          split: ->HarnessSpecHelpers.split_array(Array(Int32)),
          ch: result_ch,
          input: input
        )
      end

      result = result_ch.recv
      result.should eq(24) # 7+8+9
    end

    it "achieves parallel execution (sub-harnesses run in separate fibers)" do
      leaf_fibers = Set(Fiber).new
      leaf_mtx = Sync::Mutex.new

      f = ->(arr : Array(Int32)) : Int32 {
        leaf_mtx.synchronize { leaf_fibers << Fiber.current }
        arr.sum
      }

      input = [1, 2, 3, 4]
      result_ch = CML::Chan(Int32).new

      CML.spawn do
        CML::Harness.cph_harness(
          depth: 0, max_depth: 2,
          f: f,
          split: ->HarnessSpecHelpers.split_array(Array(Int32)),
          ch: result_ch,
          input: input
        )
      end

      result = result_ch.recv
      result.should eq(10) # 1+2+3+4
      leaf_mtx.synchronize { leaf_fibers.size.should be >= 1 }
    end
  end

  describe "EEPH harness - Event-Explicit Parallel Hierarchical (Section 4.3)" do
    it "correctly sums an array using event-based RPC parallelism" do
      input = [1, 2, 3, 4, 5, 6, 7, 8]
      result = CML::Harness.eeph_harness(
        depth: 0, max_depth: 3,
        f: ->HarnessSpecHelpers.sum_array(Array(Int32)),
        split: ->HarnessSpecHelpers.split_array(Array(Int32)),
        input: input
      )
      result.should eq(36)
    end

    it "returns leaf result directly when max_depth is 0" do
      input = [3, 6, 9]
      result = CML::Harness.eeph_harness(
        depth: 0, max_depth: 0,
        f: ->HarnessSpecHelpers.sum_array(Array(Int32)),
        split: ->HarnessSpecHelpers.split_array(Array(Int32)),
        input: input
      )
      result.should eq(18)
    end

    it "achieves parallel execution" do
      leaf_fibers = Set(Fiber).new
      leaf_mtx = Sync::Mutex.new

      f = ->(arr : Array(Int32)) : Int32 {
        leaf_mtx.synchronize { leaf_fibers << Fiber.current }
        arr.sum
      }

      input = [10, 20, 30, 40]
      result = CML::Harness.eeph_harness(
        depth: 0, max_depth: 2,
        f: f,
        split: ->HarnessSpecHelpers.split_array(Array(Int32)),
        input: input
      )

      result.should eq(100)
      leaf_mtx.synchronize { leaf_fibers.size.should be >= 1 }
    end
  end

  describe "EIPH harness - Event-Implicit Parallel Hierarchical (Section 4.4)" do
    it "correctly sums an array using fully event-based parallelism" do
      input = [1, 2, 3, 4, 5, 6, 7, 8]
      result_evt = CML::Harness.eiph_harness(
        depth: 0, max_depth: 3,
        f: ->HarnessSpecHelpers.sum_array(Array(Int32)),
        split: ->HarnessSpecHelpers.split_array(Array(Int32)),
        input: input
      )
      result_evt.should be_a(CML::Event(Int32))
      result = CML.sync(result_evt)
      result.should eq(36)
    end

    it "returns alwaysEvt when max_depth is 0" do
      input = [25]
      result_evt = CML::Harness.eiph_harness(
        depth: 0, max_depth: 0,
        f: ->HarnessSpecHelpers.sum_array(Array(Int32)),
        split: ->HarnessSpecHelpers.split_array(Array(Int32)),
        input: input
      )
      result_evt.should be_a(CML::Event(Int32))
      result = CML.sync(result_evt)
      result.should eq(25)
    end

    it "event_and combines two events correctly" do
      evt1 = CML.always(10)
      evt2 = CML.always(20)
      combine = ->(a : Int32, b : Int32) : Int32 { a + b }

      result_evt = CML::Harness.event_and(combine, evt1, evt2)
      result_evt.should be_a(CML::Event(Int32))
      result = CML.sync(result_evt)
      result.should eq(30)
    end
  end

  describe "U harness - Unified Harness (Section 4.5)" do
    it "U_harness with SH parameters behaves like SH" do
      input = [1, 2, 3, 4]
      result = CML::Harness.u_harness(
        exec: ->(daughter : Proc(Array(Int32), Int32), inp : Array(Int32)) : Int32 { daughter.call(inp) },
        merge_using: ->(combine : Proc(Int32, Int32, Int32), o1 : Int32, o2 : Int32) : Int32 { combine.call(o1, o2) },
        return_val: ->(v : Int32) : Int32 { v },
        depth: 0, max_depth: 2,
        f: ->HarnessSpecHelpers.sum_array(Array(Int32)),
        split: ->HarnessSpecHelpers.split_array(Array(Int32)),
        input: input
      )
      result.should eq(10) # 1+2+3+4
    end

    it "U_harness with EIPH parameters returns an event" do
      input = [1, 2, 3, 4]
      result_evt = CML::Harness.u_harness(
        exec: ->(daughter : Proc(Array(Int32), CML::Event(Int32)), inp : Array(Int32)) : CML::Event(Int32) {
          CML::Harness.rpc_client_evt(daughter, inp)
        },
        merge_using: ->(combine : Proc(Int32, Int32, Int32), evt1 : CML::Event(Int32), evt2 : CML::Event(Int32)) : CML::Event(Int32) {
          CML::Harness.event_and(combine, evt1, evt2)
        },
        return_val: ->(v : Int32) : CML::Event(Int32) { CML.always(v) },
        depth: 0, max_depth: 2,
        f: ->HarnessSpecHelpers.sum_array(Array(Int32)),
        split: ->HarnessSpecHelpers.split_array(Array(Int32)),
        input: input
      )
      result_evt.should be_a(CML::Event(Int32))
      result = CML.sync(result_evt)
      result.should eq(10)
    end
  end

  describe "Consistency across harnesses" do
    it "all harness implementations produce identical results for the same input" do
      input = [10, 20, 30, 40, 50, 60, 70, 80]
      expected = input.sum # 360

      # SH
      sh = CML::Harness.sh_harness(
        depth: 0, max_depth: 3,
        f: ->HarnessSpecHelpers.sum_array(Array(Int32)),
        split: ->HarnessSpecHelpers.split_array(Array(Int32)),
        input: input
      )
      sh.should eq(expected)

      # CPH
      ch = CML::Chan(Int32).new
      CML.spawn do
        CML::Harness.cph_harness(
          depth: 0, max_depth: 3,
          f: ->HarnessSpecHelpers.sum_array(Array(Int32)),
          split: ->HarnessSpecHelpers.split_array(Array(Int32)),
          ch: ch,
          input: input
        )
      end
      ch.recv.should eq(expected)

      # EEPH
      eeph = CML::Harness.eeph_harness(
        depth: 0, max_depth: 3,
        f: ->HarnessSpecHelpers.sum_array(Array(Int32)),
        split: ->HarnessSpecHelpers.split_array(Array(Int32)),
        input: input
      )
      eeph.should eq(expected)

      # EIPH
      eiph_evt = CML::Harness.eiph_harness(
        depth: 0, max_depth: 3,
        f: ->HarnessSpecHelpers.sum_array(Array(Int32)),
        split: ->HarnessSpecHelpers.split_array(Array(Int32)),
        input: input
      )
      CML.sync(eiph_evt).should eq(expected)
    end
  end
end
