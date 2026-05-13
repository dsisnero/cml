require "../src/cml"

def measure(name : String, iterations : Int32 = 1_000_000, &block)
  10_000.times { yield }

  start = Time.instant
  iterations.times { yield }
  elapsed = Time.instant - start
  nanos_per_op = elapsed.total_nanoseconds / iterations
  ops_per_sec = iterations / elapsed.total_seconds

  puts "#{name}: #{nanos_per_op.round(2)} ns/op, #{ops_per_sec.round(2)} ops/s"
end

puts "--- Hot Path Benchmark: sync(always) ---"
always_evt = CML.always(1)
measure("sync(always)") { CML.sync(always_evt) }

puts "\n--- Hot Path Benchmark: choose(always, never) ---"
choice_evt = CML.choose([CML.always(1), CML.never(Int32)])
measure("choose(always, never)") { CML.sync(choice_evt) }

puts "\n--- Hot Path Benchmark: choose(always, timeout) ---"
always_timeout_evt = CML.choose(CML.always(1), CML.timeout(1.seconds))
measure("choose(always, timeout)", iterations: 250_000) { CML.sync(always_timeout_evt) }

puts "\n--- Hot Path Benchmark: channel rendezvous two fibers ---"
measure("channel rendezvous two fibers", iterations: 10_000) do
  rendezvous_ch = CML::Chan(Int32).new
  spawn { CML.sync(rendezvous_ch.send_evt(42)) }
  CML.sync(rendezvous_ch.recv_evt)
end

puts "\n--- Hot Path Benchmark: timeout schedule+cancel ---"
measure("timeout schedule+cancel", iterations: 250_000) do
  case status = CML.timeout(1.seconds).poll
  when CML::Blocked(Nil)
    tid = CML::TransactionId.new
    status.block_fn.call(tid, -> { })
    tid.try_cancel
  else
    raise "expected timeout poll to block before scheduling"
  end
end

puts "\n--- Hot Path Benchmark: local tuple out/in round trip ---"
tuple_space = CML::TupleLib::TupleSpace.join_tuple_space
tuple = CML::TupleLib::TupleRep(CML::TupleLib::ValAtom).new(
  CML::TupleLib::Helpers.sval("bench"),
  [CML::TupleLib::Helpers.ival(42)]
)
template = CML::TupleLib::TupleRep(CML::TupleLib::PatAtom).new(
  CML::TupleLib::Helpers.sval("bench"),
  [CML::TupleLib::Helpers.iform]
)

measure("tuple out/in") do
  tuple_space.out(tuple)
  CML.sync(tuple_space.in_evt(template))
end
