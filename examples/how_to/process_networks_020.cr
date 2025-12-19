# process_networks_020.cr
# Extracted from: how_to.md
# Section: process_networks
# Lines: 534-607
#
# ----------------------------------------------------------

require "../../src/cml"

def add(in_ch1 : CML::Chan(Int32), in_ch2 : CML::Chan(Int32), out_ch : CML::Chan(Int32))
  CML.spawn do
    loop do
      # Receive from both channels (order doesn't matter with select)
      a, b = CML.sync(
        CML.choose([
          CML.wrap(in_ch1.recv_evt) { |a| {a, CML.sync(in_ch2.recv_evt)} },
          CML.wrap(in_ch2.recv_evt) { |b| {CML.sync(in_ch1.recv_evt), b} },
        ])
      )
      CML.sync(out_ch.send_evt(a + b))
    end
  end
end

def copy(in_ch : CML::Chan(Int32), out_ch1 : CML::Chan(Int32), out_ch2 : CML::Chan(Int32))
  CML.spawn do
    loop do
      x = CML.sync(in_ch.recv_evt)
      # Send to both outputs (order doesn't matter with select)
      CML.sync(
        CML.choose([
          CML.wrap(out_ch1.send_evt(x)) { out_ch2.send_evt(x) },
          CML.wrap(out_ch2.send_evt(x)) { out_ch1.send_evt(x) },
        ])
      )
    end
  end
end

def delay(initial : Int32?, in_ch : CML::Chan(Int32), out_ch : CML::Chan(Int32))
  CML.spawn do
    state = initial

    loop do
      case state
      when nil
        state = CML.sync(in_ch.recv_evt)
      else
        CML.sync(out_ch.send_evt(state))
        state = nil
      end
    end
  end
end

def make_fib_network : CML::Chan(Int32)
  out_ch = CML::Chan(Int32).new
  c1 = CML::Chan(Int32).new
  c2 = CML::Chan(Int32).new
  c3 = CML::Chan(Int32).new
  c4 = CML::Chan(Int32).new
  c5 = CML::Chan(Int32).new

  # Build the network
  delay(0, c4, c5)
  copy(c2, c3, c4)
  add(c3, c5, c1)
  copy(c1, c2, out_ch)

  # Seed with 1
  CML.spawn { CML.sync(c1.send_evt(1)) }

  out_ch
end

# Generate first 10 Fibonacci numbers
fib_ch = make_fib_network
10.times do |i|
  fib = CML.sync(fib_ch.recv_evt)
  puts "F(#{i + 1}): #{fib}"
end