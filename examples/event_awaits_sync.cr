require "../src/cml"
ch = CML::Chan(Int32).new
ev = CML.choose([ch.recv_evt, CML.always(42)])
# at this point, nothing has happened—no fiber waiting on ch
puts "before sync" # prints immediately
result = CML.sync(ev)
puts "after sync: #{result}"
