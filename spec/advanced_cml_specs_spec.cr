# spec/cml_additional_spec.cr
require "./spec_helper"

module CML
  describe "Additional CML Behavioral Specs" do
    # ------------------------------------------------------------------
    # Ivar / Mvar primitives (to be implemented later)
    # ------------------------------------------------------------------
    describe "IVar and MVar primitives" do
      it "IVar behaves as single-assignment cell" do
        iv = CML::IVar(Int32).new
        spawn { CML.sync(iv.write_evt(99)) }
        CML.sync(iv.read_evt).should eq(99)
        expect_raises(Exception) { CML.sync(iv.write_evt(42)) } # already filled
      end

      it "MVar behaves as synchronized mutable cell" do
        mv = CML::MVar(Int32).new
        spawn { CML.sync(mv.put_evt(10)) }
        CML.sync(mv.take_evt).should eq(10)
        spawn { CML.sync(mv.put_evt(20)) }
        CML.sync(mv.take_evt).should eq(20)
      end
    end

    # ------------------------------------------------------------------
    # Determinism of sync
    # ------------------------------------------------------------------
    describe "Sync determinism" do
      it "returns exactly once for any event" do
        ch = Chan(Int32).new
        ev = ch.recv_evt
        spawn { CML.sync(ch.send_evt(5)) }
        result1 = CML.sync(ev)
        result2 = CML.sync(CML.always(result1))
        result1.should eq(result2)
      end
    end

    # ------------------------------------------------------------------
    # Nack propagation and multi-layer cleanup
    # ------------------------------------------------------------------
    describe "Nested nack propagation" do
      it "runs cleanup even when wrapped and cancelled" do
        called = Atomic(Bool).new(false)
        ch = Chan(Int32).new

        wrapped_nack = CML.wrap(
          CML.nack(ch.recv_evt) { called.set(true) }
        ) { |x| x }

        # Race with timeout, expect cancellation path
        choice = CML.choose([
          wrapped_nack,
          CML.wrap(CML.timeout(0.01.seconds)) { |_t| -1 },
        ])
        CML.sync(choice)
        sleep 0.05.seconds
        called.get.should be_true
      end
    end

    # ------------------------------------------------------------------
    # Guard cancellation and side-effects
    # ------------------------------------------------------------------
    describe "Guard cancellation" do
      it "cancels side-effects when other event commits" do
        called = Atomic(Bool).new(false)
        ch = Chan(Int32).new

        guarded = CML.guard do
          spawn { called.set(true) }
          CML.timeout(0.5.seconds)
        end

        choice = CML.choose([
          guarded,
          CML.always(:immediate),
        ])
        result = CML.sync(choice)
        result.should eq(:immediate)

        # The side-effect should still have been scheduled
        sleep 0.1.seconds
        called.get.should be_true
      end
    end

    # ------------------------------------------------------------------
    # Fairness and load stress
    # ------------------------------------------------------------------
    describe "Fairness under heavy load" do
      it "ensures no fiber starvation across many choices" do
        chan = Chan(Int32).new
        results = Channel(Int32).new

        100.times do |i|
          spawn do
            choice = CML.choose([
              chan.recv_evt,
              CML.wrap(CML.timeout(0.001.seconds * (i + 1))) { |_t| i },
            ])
            results.send(CML.sync(choice))
          end
        end

        10.times { |i| spawn { CML.sync(chan.send_evt(i)) } }

        arr = (1..100).map { results.receive }
        arr.uniq.size.should eq(100)
      end
    end

    # ------------------------------------------------------------------
    # Sanity of Always/Never events
    # ------------------------------------------------------------------
    describe "Always/Never event sanity" do
      it "always event fires immediately" do
        10.times { CML.sync(CML.always(:ok)).should eq(:ok) }
      end

      it "never event never fires unless raced" do
        choice = CML.choose([
          CML.never(Int32),
          CML.wrap(CML.timeout(0.01.seconds)) { |_t| 1 },
        ])
        CML.sync(choice).should eq(1)
      end
    end
  end
end
