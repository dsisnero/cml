require "./spec_helper"

module CML
  describe "Comprehensive CML Specs" do
    describe "Nested choose operations" do
      it "handles nested choose with multiple levels" do
        ch1 = Chan(Int32).new
        ch2 = Chan(String).new
        ch3 = Chan(Symbol).new

        # Create nested choices
        inner_choice = CML.choose([ch1.recv_evt, CML.always(42)])
        outer_choice = CML.choose([
          CML.wrap(inner_choice) { |x| "inner: #{x}" },
          CML.wrap(ch2.recv_evt) { |str| "string: #{str}" },
          CML.wrap(ch3.recv_evt) { |sym| "symbol: #{sym}" },
        ])

        # Test that always event wins in inner choice
        result = CML.sync(outer_choice)
        result.should eq("inner: 42")
      end

      it "handles nested choose with timeout" do
        ch = Chan(Int32).new

        # Inner choice: channel vs timeout (both return Int32)
        inner = CML.choose([
          ch.recv_evt,
          CML.wrap(CML.timeout(0.1.seconds)) { |_t| 42 },
        ])

        # Outer choice: inner vs immediate value
        outer = CML.choose([
          CML.wrap(inner) { |x| "inner: #{x}" },
          CML.always("immediate"),
        ])

        result = CML.sync(outer)
        result.should eq("immediate")
      end

      it "handles deeply nested choose structures" do
        ch1 = Chan(Int32).new
        ch2 = Chan(Int32).new

        # Level 3: basic choice
        level3 = CML.choose([ch1.recv_evt, CML.always(3)])

        # Level 2: wrap level3
        level2 = CML.choose([
          CML.wrap(level3) { |x| x * 2 },
          CML.always(10),
        ])

        # Level 1: wrap level2
        level1 = CML.choose([
          CML.wrap(level2) { |x| x + 1 },
          ch2.recv_evt,
        ])

        result = CML.sync(level1)
        result.should eq(11) # (3 * 2) + 1 = 7, but always(10) wins in level2
      end
    end

    describe "Re-entrant guards" do
      it "executes guard block only when needed" do
        execution_count = Atomic(Int32).new(0)

        guarded = CML.guard do
          execution_count.add(1)
          CML.always(:guarded_value)
        end

        # Guard block should not execute until sync
        execution_count.get.should eq(0)

        result = CML.sync(guarded)
        result.should eq(:guarded_value)
        execution_count.get.should eq(1)
      end

      it "handles guard with conditional logic" do
        condition = Atomic(Bool).new(false)

        guarded = CML.guard do
          if condition.ge
            CML.always(:ready)
          else
            CML.timeout(0.1.seconds)
          end
        end

        # Should timeout since condition is false
        result = CML.sync(guarded)
        result.should eq(:timeout)

        # Now set condition to true and test again
        condition.set(true)
        guarded2 = CML.guard do
          if condition.ge
            CML.always(:ready)
          else
            CML.timeout(0.1.seconds)
          end
        end

        result2 = CML.sync(guarded2)
        result2.should eq(:ready)
      end

      it "handles guard that creates another guard" do
        inner_guard = CML.guard do
          CML.always(:inner)
        end

        outer_guard = CML.guard do
          inner_guard
        end

        result = CML.sync(outer_guard)
        result.should eq(:inner)
      end
    end

    describe "Multiple concurrent channels" do
      it "handles multiple channels with different types" do
        int_chan = Chan(Int32).new
        string_chan = Chan(String).new
        symbol_chan = Chan(Symbol).new

        # Create a choice across all channels
        choice = CML.choose([
          CML.wrap(int_chan.recv_evt) { |x| "int: #{x}" },
          CML.wrap(string_chan.recv_evt) { |str| "string: #{str}" },
          CML.wrap(symbol_chan.recv_evt) { |sym| "symbol: #{sym}" },
        ])

        # Send to string channel
        spawn { CML.sync(string_chan.send_evt("hello")) }

        result = CML.sync(choice)
        result.should eq("string: hello")
      end

      it "handles multiple senders and receivers" do
        chan = Chan(Int32).new

        # Multiple senders
        spawn { CML.sync(chan.send_evt(1)) }
        spawn { CML.sync(chan.send_evt(2)) }
        spawn { CML.sync(chan.send_evt(3)) }

        # Multiple receivers
        results = [] of Int32
        spawn { results << CML.sync(chan.recv_evt) }
        spawn { results << CML.sync(chan.recv_evt) }
        spawn { results << CML.sync(chan.recv_evt) }

        # Wait for all operations to complete
        sleep 0.1.seconds

        results.sort.should eq([1, 2, 3])
      end

      it "handles channel communication with many fibers" do
        chan = Chan(Int32).new
        num_fibers = 10
        results = Channel(Int32).new

        num_fibers.times do |i|
          spawn do
            CML.sync(chan.send_evt(i))
          end
          spawn do
            value = CML.sync(chan.recv_evt)
            results.send(value)
          end
        end

        received = [] of Int32
        num_fibers.times do
          received << results.receive
        end

        received.sort.should eq((0...num_fibers).to_a)
      end
    end

    describe "Timeout cancellation stress" do
      it "handles many concurrent timeouts" do
        num_timeouts = 20
        results = Channel(Symbol).new

        num_timeouts.times do |i|
          spawn do
            evt = CML.timeout(0.01.seconds * (i + 1))
            result = CML.sync(evt)
            results.send(result)
          end
        end

        received = [] of Symbol
        num_timeouts.times do
          received << results.receive
        end

        received.should eq([:timeout] * num_timeouts)
      end

      it "handles timeout cancellation with many fibers" do
        chan = Chan(Int32).new
        num_fibers = 15
        results = Channel(Int32).new

        num_fibers.times do |_|
          spawn do
            choice = CML.choose([
              chan.recv_evt,
              CML.wrap(CML.timeout(0.5.seconds)) { |_t| -1 },
            ])
            result = CML.sync(choice)
            results.send(result)
          end
        end

        # Send some values
        5.times do |i|
          spawn { CML.sync(chan.send_evt(i + 100)) }
        end

        received = [] of Int32
        num_fibers.times do
          received << results.receive
        end

        # Should have 5 numbers and 10 timeouts (wrapped to -1)
        numbers = received.select { |x| x >= 100 }.sort!
        timeouts = received.select { |x| x == -1 }

        numbers.should eq([100, 101, 102, 103, 104])
        timeouts.size.should eq(10)
      end

      it "handles rapid timeout creation and cancellation" do
        # Create many timeouts in quick succession
        timeouts = [] of Event(Symbol)
        50.times do |i|
          timeouts << CML.timeout(0.001.seconds * (i + 1))
        end

        # Sync on a choice that includes all timeouts
        choice = CML.choose(timeouts + [CML.always(:immediate)])
        result = CML.sync(choice)

        result.should eq(:immediate)
      end
    end

    describe "Event composition patterns" do
      it "handles wrap with transformation" do
        ch = Chan(Int32).new
        wrapped = CML.wrap(ch.recv_evt) { |x| x * 2 }

        spawn { CML.sync(ch.send_evt(21)) }
        result = CML.sync(wrapped)
        result.should eq(42)
      end

      it "handles nack cleanup" do
        cleanup_called = Atomic(Bool).new(false)
        ch = Chan(Int32).new

        nacked = CML.nack(ch.send_evt(42)) do
          cleanup_called.set(true)
        end

        # Race the nacked send against a timeou
        choice = CML.choose([
          CML.wrap(nacked) { |_| :nacked },
          CML.timeout(0.5.seconds),
        ])

        result = CML.sync(choice)
        result.should eq(:timeout)

        # Give time for cleanup to run
        sleep 0.5.seconds
        cleanup_called.get.should be_true
      end

      it "handles complex event chains" do
        ch1 = Chan(Int32).new
        # Build a complex chain: guard -> wrap -> choose -> nack
        complex = CML.guard do
          inner = CML.wrap(ch1.recv_evt, &.to_s)
          choice = CML.choose([inner, CML.always("default")])
          CML.nack(choice) { puts "Complex chain cancelled" }
        end

        result = CML.sync(complex)
        result.should eq("default")
      end
    end
  end
end
