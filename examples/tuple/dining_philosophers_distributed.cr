require "option_parser"
require "../../src/cml"

module Chapter9DistributedDining
  alias L = CML::Linda

  TAG_CHOPSTICK = L::Helpers.sval("chopstick")
  TAG_TICKET    = L::Helpers.sval("ticket")
  TAG_READY     = L::Helpers.sval("ready")

  private def self.chopstick_tuple(pos : Int32) : L::Tuple
    L::TupleRep(L::ValAtom).new(TAG_CHOPSTICK, [L::Helpers.ival(pos)])
  end

  private def self.ticket_tuple : L::Tuple
    L::TupleRep(L::ValAtom).new(TAG_TICKET, [] of L::ValAtom)
  end

  private def self.ticket_template : L::Template
    L::TupleRep(L::PatAtom).new(TAG_TICKET, [] of L::PatAtom)
  end

  private def self.chopstick_template(pos : Int32) : L::Template
    L::TupleRep(L::PatAtom).new(TAG_CHOPSTICK, [L::Helpers.ipat(pos)])
  end

  private def self.ready_tuple(id : Int32) : L::Tuple
    L::TupleRep(L::ValAtom).new(TAG_READY, [L::Helpers.ival(id)])
  end

  private def self.ready_template(id : Int32) : L::Template
    L::TupleRep(L::PatAtom).new(TAG_READY, [L::Helpers.ipat(id)])
  end

  private def self.input(space : L::TupleSpace, template : L::Template) : Array(L::ValAtom)
    CML.sync(space.in_evt(template))
  end

  private def self.log(verbose : Bool, message : String)
    puts message if verbose
  end

  def self.run(local_port : Int32, remote_hosts : Array(String), num_phils : Int32, rounds : Int32, startup_delay : Float64, linger : Float64, verbose : Bool)
    raise "num_phils must be >= 2" if num_phils < 2
    raise "rounds must be >= 1" if rounds < 1

    phil_id = remote_hosts.size.to_i32
    left = phil_id
    right = (phil_id + 1) % num_phils

    space = L.join_tuple_space(local_port: local_port, remote_hosts: remote_hosts)

    # Allow the chapter-style incremental join to stabilize TCP proxy links
    # before transactional IN/RD traffic starts.
    sleep startup_delay.seconds if startup_delay > 0.0

    # Chapter 9 distributed init pattern.
    if phil_id == 0
      space.out(chopstick_tuple(0))
      log(verbose, "node=#{phil_id} init out chopstick=0")
    else
      space.out(chopstick_tuple(phil_id))
      space.out(ticket_tuple)
      log(verbose, "node=#{phil_id} init out chopstick=#{phil_id}")
      log(verbose, "node=#{phil_id} init out ticket")
    end

    # Startup barrier: make sure all members are present before dining rounds.
    # Use in/out tokens to avoid rd/hold cancellation edge cases under contention.
    space.out(ready_tuple(phil_id))
    num_phils.times do |id|
      input(space, ready_template(id.to_i32))
      space.out(ready_tuple(id.to_i32))
    end

    rounds.times do |round|
      log(verbose, "node=#{phil_id} round=#{round + 1} wait ticket")
      input(space, ticket_template)
      log(verbose, "node=#{phil_id} round=#{round + 1} got ticket")
      log(verbose, "node=#{phil_id} round=#{round + 1} wait chopstick=#{left}")
      input(space, chopstick_template(left))
      log(verbose, "node=#{phil_id} round=#{round + 1} got chopstick=#{left}")
      log(verbose, "node=#{phil_id} round=#{round + 1} wait chopstick=#{right}")
      input(space, chopstick_template(right))
      log(verbose, "node=#{phil_id} round=#{round + 1} got chopstick=#{right}")

      puts "node=#{phil_id} round=#{round + 1} eat"

      space.out(chopstick_tuple(left))
      log(verbose, "node=#{phil_id} round=#{round + 1} out chopstick=#{left}")
      space.out(chopstick_tuple(right))
      log(verbose, "node=#{phil_id} round=#{round + 1} out chopstick=#{right}")
      space.out(ticket_tuple)
      log(verbose, "node=#{phil_id} round=#{round + 1} out ticket")

      Fiber.yield
    end

    # Keep the node alive briefly so final asynchronous out(...) operations
    # are flushed through proxy/output fibers before process exit.
    sleep linger.seconds if linger > 0.0

    puts "node=#{phil_id} done"
  end
end

local_port = 7100
remote_hosts = [] of String
num_phils = 3
rounds = 2
startup_delay = 2.0_f64
verbose = false
linger = 1.0_f64

OptionParser.parse do |parser|
  parser.banner = "Usage: crystal run dining_philosophers_distributed.cr -- [options]"

  parser.on("--local-port PORT", "Local tuple-space server port (default: 7100)") { |v| local_port = v.to_i }
  parser.on("--remote-hosts HOSTS", "Comma-separated remote hosts host[:port]") do |v|
    remote_hosts = v.split(',').map(&.strip).reject(&.empty?)
  end
  parser.on("--philosophers N", "Total philosophers/nodes (default: 3)") { |v| num_phils = v.to_i }
  parser.on("--rounds N", "Rounds per node (default: 2)") { |v| rounds = v.to_i }
  parser.on("--startup-delay SECONDS", "Delay before starting protocol (default: 2.0)") { |v| startup_delay = v.to_f64 }
  parser.on("--linger SECONDS", "Delay before process exit to flush async output (default: 1.0)") { |v| linger = v.to_f64 }
  parser.on("--verbose", "Enable verbose protocol logs") { verbose = true }
  parser.on("-h", "--help", "Show help") { puts parser; exit(0) }
end

Chapter9DistributedDining.run(local_port, remote_hosts, num_phils, rounds, startup_delay, linger, verbose)
