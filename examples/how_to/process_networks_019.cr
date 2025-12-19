# process_networks_019.cr
# Extracted from: how_to.md
# Section: process_networks
# Lines: 478-530
#
# ----------------------------------------------------------

require "../../src/cml"

def make_nat_stream(start : Int32 = 0) : CML::Chan(Int32)
  ch = CML::Chan(Int32).new

  CML.spawn do
    i = start
    loop do
      CML.sync(ch.send_evt(i))
      i += 1
    end
  end

  ch
end

def filter(p : Int32, in_ch : CML::Chan(Int32)) : CML::Chan(Int32)
  out_ch = CML::Chan(Int32).new

  CML.spawn do
    loop do
      i = CML.sync(in_ch.recv_evt)
      if i % p != 0
        CML.sync(out_ch.send_evt(i))
      end
    end
  end

  out_ch
end

def sieve : CML::Chan(Int32)
  primes_ch = CML::Chan(Int32).new

  CML.spawn do
    ch = make_nat_stream(2)

    loop do
      p = CML.sync(ch.recv_evt)
      CML.sync(primes_ch.send_evt(p))
      ch = filter(p, ch)
    end
  end

  primes_ch
end

# Get first 10 primes
primes_ch = sieve
10.times do |i|
  prime = CML.sync(primes_ch.recv_evt)
  puts "Prime #{i + 1}: #{prime}"
end
