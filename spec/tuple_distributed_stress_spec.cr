require "./spec_helper"

private def sync_evt_with_timeout(evt : CML::Event(T), label : String, timeout = 10.seconds) : T forall T
  result = CML.select(evt, CML.timeout(timeout))
  result.should_not be_nil, "timed out waiting for #{label} after #{timeout.total_seconds}s"
  result.as(T)
end

private def receive_with_timeout(ch : Channel(Int32), label : String, timeout = 20.seconds) : Int32
  select
  when id = ch.receive
    id
  when timeout(timeout)
    fail "timed out waiting for #{label} after #{timeout.total_seconds}s"
    raise "unreachable"
  end
end

private def run_distributed_dining_once(base_port : Int32, rounds : Int32, run_label : String, per_step_timeout = 20.seconds)
  ts0 = CML::TupleLib::TupleSpace.join_tuple_space(
    local_port: base_port,
    remote_hosts: [] of String
  )
  ts1 = CML::TupleLib::TupleSpace.join_tuple_space(
    local_port: base_port + 1,
    remote_hosts: ["127.0.0.1:#{base_port}"]
  )
  ts2 = CML::TupleLib::TupleSpace.join_tuple_space(
    local_port: base_port + 2,
    remote_hosts: ["127.0.0.1:#{base_port}", "127.0.0.1:#{base_port + 1}"]
  )

  tag_chopstick = CML::TupleLib::Helpers.sval("chopstick")
  tag_ticket = CML::TupleLib::Helpers.sval("ticket")
  tag_ready = CML::TupleLib::Helpers.sval("ready")

  chopstick_tuple = ->(pos : Int32) {
    CML::TupleLib::TupleRep(CML::TupleLib::ValAtom).new(tag_chopstick, [CML::TupleLib::Helpers.ival(pos)])
  }
  chopstick_template = ->(pos : Int32) {
    CML::TupleLib::TupleRep(CML::TupleLib::PatAtom).new(tag_chopstick, [CML::TupleLib::Helpers.ipat(pos)])
  }
  ticket_tuple = -> {
    CML::TupleLib::TupleRep(CML::TupleLib::ValAtom).new(tag_ticket, [] of CML::TupleLib::ValAtom)
  }
  ticket_template = -> {
    CML::TupleLib::TupleRep(CML::TupleLib::PatAtom).new(tag_ticket, [] of CML::TupleLib::PatAtom)
  }
  ready_tuple = ->(id : Int32) {
    CML::TupleLib::TupleRep(CML::TupleLib::ValAtom).new(tag_ready, [CML::TupleLib::Helpers.ival(id)])
  }
  ready_template = ->(id : Int32) {
    CML::TupleLib::TupleRep(CML::TupleLib::PatAtom).new(tag_ready, [CML::TupleLib::Helpers.ipat(id)])
  }

  spaces = [ts0, ts1, ts2]
  done = Channel(Int32).new(3)
  num_phils = 3

  spaces.each_with_index do |space, id|
    CML.spawn do
      phil_id = id.to_i32
      left = phil_id
      right = (phil_id + 1) % num_phils

      if phil_id == 0
        space.out(chopstick_tuple.call(0))
      else
        space.out(chopstick_tuple.call(phil_id))
        space.out(ticket_tuple.call)
      end

      space.out(ready_tuple.call(phil_id))
      num_phils.times do |peer|
        sync_evt_with_timeout(space.in_evt(ready_template.call(peer.to_i32)), "#{run_label} node=#{phil_id} ready in #{peer}", per_step_timeout)
        space.out(ready_tuple.call(peer.to_i32))
      end

      rounds.times do |round|
        sync_evt_with_timeout(space.in_evt(ticket_template.call), "#{run_label} node=#{phil_id} ticket round=#{round + 1}", per_step_timeout)
        sync_evt_with_timeout(space.in_evt(chopstick_template.call(left)), "#{run_label} node=#{phil_id} left=#{left} round=#{round + 1}", per_step_timeout)
        sync_evt_with_timeout(space.in_evt(chopstick_template.call(right)), "#{run_label} node=#{phil_id} right=#{right} round=#{round + 1}", per_step_timeout)

        space.out(chopstick_tuple.call(left))
        space.out(chopstick_tuple.call(right))
        space.out(ticket_tuple.call)
      end

      done.send(phil_id)
    end
  end

  finished = [] of Int32
  3.times do |i|
    finished << receive_with_timeout(done, "#{run_label} distributed philosopher completion #{i + 1}", 75.seconds)
  end
  finished.sort.should eq([0, 1, 2])
end

describe "CML::TupleLib distributed stress" do
  it "runs chapter-9 dining pattern across 3 tuple spaces without hanging" do
    base_port = 7900 + Random.rand(200)

    begin
      ts0 = CML::TupleLib::TupleSpace.join_tuple_space(
        local_port: base_port,
        remote_hosts: [] of String
      )
      ts1 = CML::TupleLib::TupleSpace.join_tuple_space(
        local_port: base_port + 1,
        remote_hosts: ["127.0.0.1:#{base_port}"]
      )
      ts2 = CML::TupleLib::TupleSpace.join_tuple_space(
        local_port: base_port + 2,
        remote_hosts: ["127.0.0.1:#{base_port}", "127.0.0.1:#{base_port + 1}"]
      )

      tag_chopstick = CML::TupleLib::Helpers.sval("chopstick")
      tag_ticket = CML::TupleLib::Helpers.sval("ticket")
      tag_ready = CML::TupleLib::Helpers.sval("ready")

      chopstick_tuple = ->(pos : Int32) {
        CML::TupleLib::TupleRep(CML::TupleLib::ValAtom).new(tag_chopstick, [CML::TupleLib::Helpers.ival(pos)])
      }
      chopstick_template = ->(pos : Int32) {
        CML::TupleLib::TupleRep(CML::TupleLib::PatAtom).new(tag_chopstick, [CML::TupleLib::Helpers.ipat(pos)])
      }
      ticket_tuple = -> {
        CML::TupleLib::TupleRep(CML::TupleLib::ValAtom).new(tag_ticket, [] of CML::TupleLib::ValAtom)
      }
      ticket_template = -> {
        CML::TupleLib::TupleRep(CML::TupleLib::PatAtom).new(tag_ticket, [] of CML::TupleLib::PatAtom)
      }
      ready_tuple = ->(id : Int32) {
        CML::TupleLib::TupleRep(CML::TupleLib::ValAtom).new(tag_ready, [CML::TupleLib::Helpers.ival(id)])
      }
      ready_template = ->(id : Int32) {
        CML::TupleLib::TupleRep(CML::TupleLib::PatAtom).new(tag_ready, [CML::TupleLib::Helpers.ipat(id)])
      }

      spaces = [ts0, ts1, ts2]
      done = Channel(Int32).new(3)
      rounds = 4
      num_phils = 3

      spaces.each_with_index do |space, id|
        CML.spawn do
          phil_id = id.to_i32
          left = phil_id
          right = (phil_id + 1) % num_phils

          # Chapter 9 init pattern.
          if phil_id == 0
            space.out(chopstick_tuple.call(0))
          else
            space.out(chopstick_tuple.call(phil_id))
            space.out(ticket_tuple.call)
          end

          # Startup barrier using in/out tokens to avoid rd hold races.
          space.out(ready_tuple.call(phil_id))
          num_phils.times do |peer|
            sync_evt_with_timeout(space.in_evt(ready_template.call(peer.to_i32)), "node=#{phil_id} ready in #{peer}", 20.seconds)
            space.out(ready_tuple.call(peer.to_i32))
          end

          rounds.times do |round|
            sync_evt_with_timeout(space.in_evt(ticket_template.call), "node=#{phil_id} ticket round=#{round + 1}", 20.seconds)
            sync_evt_with_timeout(space.in_evt(chopstick_template.call(left)), "node=#{phil_id} left=#{left} round=#{round + 1}", 20.seconds)
            sync_evt_with_timeout(space.in_evt(chopstick_template.call(right)), "node=#{phil_id} right=#{right} round=#{round + 1}", 20.seconds)

            space.out(chopstick_tuple.call(left))
            space.out(chopstick_tuple.call(right))
            space.out(ticket_tuple.call)
          end

          done.send(phil_id)
        end
      end

      finished = [] of Int32
      3.times do |i|
        finished << receive_with_timeout(done, "distributed philosopher completion #{i + 1}", 75.seconds)
      end
      finished.sort.should eq([0, 1, 2])
    rescue ex : ::Socket::Error
      pending!("cannot create distributed tuple-space sockets in this environment: #{ex.message}")
    end
  end

  it "repeats distributed chapter-9 dining across deterministic port ranges and fails on first hang" do
    # This spec intentionally has no teardown between iterations because TupleSpace
    # currently has no close/shutdown API. Keep default loops conservative to avoid
    # cross-iteration interference in normal CI/local runs; larger stress loops
    # remain available via CML_DISTRIBUTED_STRESS_LOOPS.
    loops = (ENV["CML_DISTRIBUTED_STRESS_LOOPS"]? || "1").to_i
    rounds = (ENV["CML_DISTRIBUTED_STRESS_ROUNDS"]? || "2").to_i
    base_start = (ENV["CML_DISTRIBUTED_STRESS_BASE_PORT"]? || "9000").to_i

    begin
      loops.times do |i|
        run_distributed_dining_once(
          base_port: (base_start + i * 10).to_i32,
          rounds: rounds.to_i32,
          run_label: "iter=#{i + 1} base_port=#{base_start + i * 10}"
        )
      end
    rescue ex : ::Socket::Error
      pending!("cannot create distributed tuple-space sockets in this environment: #{ex.message}")
    end
  end
end
