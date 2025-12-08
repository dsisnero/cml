require "./spec_helper"

module CML
  describe "Nested Choose Operations" do
    describe "Basic nested choose patterns" do
      it "handles simple two-level nesting" do
        ch1 = Chan(Int32).new
        ch2 = Chan(String).new

        # Inner choice between channel and always - both Int32
        inner = CML.choose(
          ch1.recv_evt,
          CML.always(42),
        )

        # Outer choice between inner result and another channel - both String
        outer = CML.choose(
          CML.wrap(inner) { |x| "inner: #{x}" },
          CML.wrap(ch2.recv_evt) { |str| "string: #{str}" },
        )

        # Always event should win immediately
        result = CML.sync(outer)
        result.should eq("inner: 42")
      end

      it "handles nested choose with channel communication" do
        ch1 = Chan(Int32).new
        ch2 = Chan(Int32).new
        ch3 = Chan(Int32).new

        # Send to ch1 FIRST so it's ready before we construct the choice
        spawn { CML.sync(ch1.send_evt(21)) }
        sleep 10.milliseconds # Give sender time to register

        # Inner choice between ch1 and ch3 - ch1 should win since it's ready
        inner = CML.choose(
          ch1.recv_evt,
          ch3.recv_evt,
        )

        # Outer choice between inner and ch2
        outer = CML.choose(
          CML.wrap(inner) { |x| x * 2 },
          ch2.recv_evt,
        )

        result = CML.sync(outer)
        result.should eq(42)
      end
    end

    describe "Deep nesting scenarios" do
      it "handles three-level deep nesting" do
        ch1 = Chan(Int32).new
        ch2 = Chan(String).new
        ch3 = Chan(Symbol).new

        # Level 3: basic choice - both Int32
        level3 = CML.choose(
          ch1.recv_evt,
          CML.always(100),
        )

        # Level 2: transform level3 result - both String
        level2 = CML.choose(
          CML.wrap(level3, &.to_s),
          CML.wrap(ch2.recv_evt, &.upcase),
        )

        # Level 1: final transformation - both String
        level1 = CML.choose(
          CML.wrap(level2) { |str| "result: #{str}" },
          CML.wrap(ch3.recv_evt) { |sym| "symbol: #{sym}" },
        )

        result = CML.sync(level1)
        result.should eq("result: 100")
      end

      it "handles branching nested structures" do
        ch1 = Chan(Int32).new
        ch2 = Chan(Int32).new

        # Create two independent inner choices - both Int32
        inner_left = CML.choose(
          ch1.recv_evt,
          CML.always(10),
        )

        inner_right = CML.choose(
          ch2.recv_evt,
          CML.always(20),
        )

        # Outer choice combines both branches - both Int32
        outer = CML.choose(
          CML.wrap(inner_left) { |x| x + 1 },
          CML.wrap(inner_right) { |x| x + 2 },
        )

        result = CML.sync(outer)
        # inner_left should win (first in array)
        result.should eq(11)
      end
    end

    describe "Nested choose with timeouts" do
      it "handles nested timeout cancellation" do
        ch = Chan(Int32).new

        # Inner choice with timeout - both return String
        inner = CML.choose(
          CML.wrap(ch.recv_evt) { |x| x.to_s },
          CML.wrap(CML.timeout(0.1.seconds)) { |_t| "-1" },
        )

        # Outer choice with shorter timeout - both String
        outer = CML.choose(
          CML.wrap(inner) { |x| "inner: #{x}" },
          CML.wrap(CML.timeout(0.05.seconds)) { |_t| "outer_timeout" },
        )

        result = CML.sync(outer)
        result.should eq("outer_timeout")
      end

      it "handles timeout in inner choice winning" do
        ch = Chan(Int32).new

        # Inner choice with very short timeout - both String
        inner = CML.choose(
          CML.wrap(ch.recv_evt) { |x| x.to_s },
          CML.wrap(CML.timeout(0.01.seconds)) { |_t| "timeout" },
        )

        # Outer choice with longer timeout - both String
        outer = CML.choose(
          CML.wrap(inner) { |x| "inner: #{x}" },
          CML.wrap(CML.timeout(0.5.seconds)) { |_t| "outer_timeout" },
        )

        result = CML.sync(outer)
        result.should eq("inner: timeout")
      end
    end

    describe "Complex nested patterns" do
      it "handles nested choose with guards" do
        execution_count = Atomic(Int32).new(0)

        # Guard that creates a choice - both Symbol
        guarded_choice = CML.guard do
          execution_count.add(1)
          CML.choose(
            CML.always(:from_guard),
            CML.wrap(CML.timeout(0.1.seconds)) { |t| t },
          )
        end

        # Outer choice including the guarded choice - both Symbol
        outer = CML.choose(
          guarded_choice,
          CML.always(:immediate),
        )

        # Guard should not execute until sync
        execution_count.get.should eq(0)

        result = CML.sync(outer)
        result.should eq(:immediate)
        execution_count.get.should eq(0) # Guard not executed since immediate won
      end

      it "handles nested choose with wrap transformations" do
        ch1 = Chan(Int32).new
        ch2 = Chan(String).new

        # Complex transformation chain - all Int32
        result = CML.sync(
          CML.choose(
            CML.wrap(
              CML.choose(
                CML.wrap(ch1.recv_evt) { |x| x * 2 },
                CML.always(5),
              )
            ) { |x| x + 1 },
            CML.wrap(ch2.recv_evt, &.size),
          )
        )

        result.should eq(6) # (5 + 1) from the always branch
      end

      it "handles nested choose_all patterns" do
        ch1 = Chan(Int32).new
        ch2 = Chan(String).new

        # Inner choose_all
        inner_all = CML.choose_all(
          CML.always(1),
          CML.always(2),
        )

        # Outer choice with choose_all result - all Int32
        outer = CML.choose(
          CML.wrap(inner_all, &.sum),
          CML.wrap(ch1.recv_evt) { |x| x * 10 },
          CML.wrap(ch2.recv_evt) { |str| str.to_i? || 0 },
        )

        result = CML.sync(outer)
        result.should eq(3) # 1 + 2 from choose_all
      end
    end

    describe "Edge cases and error scenarios" do
      it "handles empty nested choices" do
        # Empty inner choice
        empty_inner = CML.choose(Array(Event(Int32)).new)

        # Outer choice with empty inner - both String
        outer = CML.choose(
          CML.wrap(empty_inner) { |x| "inner: #{x}" },
          CML.always("fallback"),
        )

        result = CML.sync(outer)
        result.should eq("fallback")
      end

      it "handles nested choose with same channel multiple times" do
        ch = Chan(Int32).new

        # Send value FIRST so channel is ready
        spawn { CML.sync(ch.send_evt(42)) }
        sleep 10.milliseconds

        # Multiple choices on same channel - all String
        inner1 = ch.recv_evt
        inner2 = ch.recv_evt

        outer = CML.choose(
          CML.wrap(inner1) { |x| "first: #{x}" },
          CML.wrap(inner2) { |x| "second: #{x}" },
        )

        result = CML.sync(outer)
        # One of the channel events should win
        (result.starts_with?("first: 42") || result.starts_with?("second: 42")).should be_true
      end

      it "handles deeply nested timeout stress" do
        # Create a deeply nested timeout structure - all Symbol
        current = CML.wrap(CML.timeout(1.second)) { |t| t }
        10.times do |_|
          current = CML.choose(
            CML.wrap(current) { |_t| :timeout },
            CML.always(:immediate),
          )
        end

        result = CML.sync(current)
        # The always(:immediate) wins at some level, but wrap transforms it to :timeout
        # at the outer layers. Result depends on how deep always wins.
        # With ChooseEvt.poll, inner always wins but gets wrapped to :timeout.
        (result == :immediate || result == :timeout).should be_true
      end
    end

    describe "Performance and concurrency" do
      it "handles many concurrent nested choices" do
        num_choices = 10
        results = Channel(String).new

        num_choices.times do |i|
          spawn do
            # Create nested choice for each fiber - inner: Int32 | Symbol -> String
            inner = CML.choose(
              CML.wrap(CML.always(i)) { |x| x.to_s },
              CML.wrap(CML.timeout(0.5.seconds)) { |_t| "timeout" },
            )

            # Outer choice - both String
            outer = CML.choose(
              CML.wrap(inner) { |x| "fiber_#{x}" },
              CML.wrap(CML.timeout(1.second)) { |_t| "outer_timeout" },
            )

            result = CML.sync(outer)
            results.send(result)
          end
        end

        received = Array(String).new
        num_choices.times do
          received << results.receive
        end

        received.sort.should eq((0...num_choices).map { |i| "fiber_#{i}" })
      end

      it "handles nested choice with many alternatives" do
        # Create many alternatives in nested structure
        alternatives = Array(Event(Int32)).new
        20.times do |i|
          alternatives << CML.always(i)
        end

        # Nested choice with many alternatives - both Int32
        inner = CML.choose(alternatives)
        outer = CML.choose(
          CML.wrap(inner) { |x| x * 2 },
          CML.always(-1),
        )

        result = CML.sync(outer)
        result.should eq(0) # First always wins
      end
    end
  end
end