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
  end
end
