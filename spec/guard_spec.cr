require "spec"
require "../src/cml"

describe CML do
  describe "guard laziness semantics" do
    it "does not evaluate the guard thunk during poll when another branch is immediately ready" do
      side_effect = Atomic(Bool).new(false)

      guarded = CML.guard do
        side_effect.set(true)
        CML.always(:guard)
      end

      # Place the guarded branch first to ensure ChooseEvt.poll sees it before the always(:other)
      chosen = CML.sync(CML.choose(guarded, CML.always(:other)))

      chosen.should eq(:other)
      # Strict laziness: the guard thunk must not run in poll fast path
      side_effect.get.should be_false
    end

    it "evaluates the guard thunk exactly once when the guarded branch wins" do
      count = Atomic(Int32).new(0)
      ch = CML::Chan(Int32).new

      guarded = CML.guard do
        count.add(1)
        ch.recv_evt
      end

      spawn do
        CML.sync(ch.send_evt(41))
      end

      val = CML.sync(guarded)
      val.should eq(41)
      count.get.should eq(1)
    end

    it "evaluates the guard thunk on registration when racing timeout; abort cleanup runs on losing" do
      # We simulate side-effect + cleanup using wrap_abort on the inner event
      effect = Atomic(Int32).new(0)

      guarded = CML.guard do
        effect.set(1)
        # Inner event never completes; on losing, wrap_abort should run cleanup
        CML.wrap_abort(CML.never(Nil), -> : Nil { effect.set(0); nil }) { |_| nil }
      end

      # Race guard vs immediate timeout; place timeout second so poll sees guard first (which now returns nil)
      res = CML.sync(CML.choose(guarded, CML.timeout(1.millisecond)))
      res.should eq(:timeout)

      # Thunk should have run during registration attempt (since no poll-win),
      # and abort cleanup should reset the effect when losing the choose.
      effect.get.should eq(0)
    end

    it "handles re-entrant guards with nested choose" do
      execution_count = Atomic(Int32).new(0)
      ch1 = CML::Chan(Int32).new
      ch2 = CML::Chan(String).new

      # Guard that creates a complex nested choice
      guarded = CML.guard do
        execution_count.add(1)
        inner_choice = CML.choose([
          CML.wrap(ch1.recv_evt) { |x| x * 2 },
          CML.always(42),
        ])
        CML.choose([
          CML.wrap(inner_choice) { |x| "inner: #{x}" },
          CML.wrap(ch2.recv_evt) { |str| "string: #{str}" },
        ])
      end

      # Guard should not execute until sync
      execution_count.get.should eq(0)

      # Test with immediate alternative
      # The guard is forced first (during try_register), producing an event
      # with always(42) inside. Then polling happens, and the guard's
      # inner always(42) wins before "immediate" is polled.
      result = CML.sync(CML.choose([
        guarded,
        CML.always("immediate"),
      ]))
      # Guard was executed during force phase, and its inner always(42) won
      # because guard result's try_register ran first in the loop
      result.should eq("inner: 42")
      execution_count.get.should eq(1) # Guard WAS executed during force phase

      # Now test with guard winning again (second sync)
      spawn { CML.sync(ch1.send_evt(21)) }
      result2 = CML.sync(guarded)
      result2.should eq("inner: 42") # Always wins in inner choice
      execution_count.get.should eq(2) # Guard executed again
    end

    it "handles deeply re-entrant guard chains" do
      # Use individual Atomic variables to avoid struct-copy issue with arrays
      count0 = Atomic(Int32).new(0)
      count1 = Atomic(Int32).new(0)
      count2 = Atomic(Int32).new(0)

      # Create a chain of guards
      guard3 = CML.guard do
        count2.add(1)
        CML.always(:level3)
      end

      guard2 = CML.guard do
        count1.add(1)
        CML.choose([
          guard3,
          CML.always(:level2_fallback),
        ])
      end

      guard1 = CML.guard do
        count0.add(1)
        CML.choose([
          guard2,
          CML.always(:level1_fallback),
        ])
      end

      # None should execute until sync
      count0.get.should eq(0)
      count1.get.should eq(0)
      count2.get.should eq(0)

      result = CML.sync(guard1)
      result.should eq(:level3)
      count0.get.should eq(1)
      count1.get.should eq(1)
      count2.get.should eq(1)
    end

    it "handles re-entrant guards with timeout cancellation" do
      execution_count = Atomic(Int32).new(0)
      cleanup_count = Atomic(Int32).new(0)

      guarded = CML.guard do
        execution_count.add(1)
        # Create a choice that will timeout - wrap never to return Symbol
        inner = CML.choose(
          CML.wrap(CML.never(Int32)) { |_| :never },
          CML.wrap(CML.timeout(0.1.seconds)) { |_t| :inner_timeout },
        )
        CML.nack(inner) { cleanup_count.add(1) }
      end

      # Race against immediate timeout - both return Symbol
      result = CML.sync(CML.choose(
        guarded,
        CML.wrap(CML.timeout(0.01.seconds)) { |t| t },
      ))

      result.should eq(:timeout)
      execution_count.get.should eq(1) # Guard executed during registration
      # Give time for cleanup to potentially run
      sleep 0.1.seconds
      cleanup_count.get.should eq(1) # Nack cleanup should run
    end

    it "handles re-entrant guards with dynamic channel creation" do
      execution_count = Atomic(Int32).new(0)
      results = Array(String).new

      3.times do |i|
        spawn do
          # Each fiber creates its own guarded choice with dynamically created channels
          guarded = CML.guard do
            execution_count.add(1)
            ch = CML::Chan(Int32).new
            spawn { CML.sync(ch.send_evt(i)) }
            CML.wrap(ch.recv_evt) { |x| "fiber_#{x}" }
          end

          result = CML.sync(guarded)
          results << result
        end
      end

      # Wait for all fibers to complete
      sleep 0.1.seconds
      results.sort.should eq(["fiber_0", "fiber_1", "fiber_2"])
      execution_count.get.should eq(3)
    end

    it "handles re-entrant guards with conditional logic and side effects" do
      condition = Atomic(Bool).new(false)
      execution_count = Atomic(Int32).new(0)

      guarded = CML.guard do
        execution_count.add(1)
        if condition.get
          CML.always(:ready)
        else
          # Create a complex nested structure when condition is false
          inner = CML.choose([
            CML.never(Symbol),
            CML.wrap(CML.timeout(0.05.seconds)) { |_t| :timeout },
          ])
          CML.choose([
            inner,
            CML.always(:fallback),
          ])
        end
      end

      # Test with condition false
      result1 = CML.sync(guarded)
      result1.should eq(:fallback)
      execution_count.get.should eq(1)

      # Reset and test with condition true
      execution_count.set(0)
      condition.set(true)
      result2 = CML.sync(guarded)
      result2.should eq(:ready)
      execution_count.get.should eq(1)
    end
  end
end
