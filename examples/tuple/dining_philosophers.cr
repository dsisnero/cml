require "option_parser"
require "../../src/cml"

module Chapter9Dining
  alias L = CML::Linda

  TAG_CHOPSTICK = L::Helpers.sval("chopstick")
  TAG_TICKET    = L::Helpers.sval("ticket")

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

  private def self.input_with_timeout(space : L::TupleSpace, template : L::Template, label : String, timeout = 10.seconds) : Array(L::ValAtom)
    result = CML.select(space.in_evt(template), CML.timeout(timeout))
    raise "timed out waiting for #{label} after #{timeout.total_seconds}s" if result.nil?
    result.as(Array(L::ValAtom))
  end

  private def self.philosopher(space : L::TupleSpace, server_id : Int32, phil_id : Int32, num_phils : Int32, rounds : Int32, done : Channel(Nil))
    spawn do
      # Chapter 9 distributed init policy: id 0 contributes one chopstick,
      # all others contribute one chopstick + one ticket.
      if phil_id == 0
        space.out(chopstick_tuple(0))
      else
        space.out(chopstick_tuple(phil_id))
        space.out(ticket_tuple)
      end

      left = phil_id
      right = (phil_id + 1) % num_phils

      rounds.times do |round|
        input_with_timeout(space, ticket_template, "ticket(server=#{server_id}, phil=#{phil_id})")
        input_with_timeout(space, chopstick_template(left), "left chopstick #{left}(server=#{server_id}, phil=#{phil_id})")
        input_with_timeout(space, chopstick_template(right), "right chopstick #{right}(server=#{server_id}, phil=#{phil_id})")

        puts "server=#{server_id} philosopher=#{phil_id} round=#{round + 1} eat"

        space.out(chopstick_tuple(left))
        space.out(chopstick_tuple(right))
        space.out(ticket_tuple)

        Fiber.yield
      end

      done.send(nil)
    end
  end

  def self.run(servers : Int32, philosophers : Int32, rounds : Int32)
    raise "servers must be >= 1" if servers < 1
    raise "philosophers must be >= 2" if philosophers < 2
    raise "rounds must be >= 1" if rounds < 1

    done = Channel(Nil).new

    servers.times do |server_id|
      space = L.join_tuple_space
      philosophers.times do |phil_id|
        philosopher(space, server_id, phil_id, philosophers, rounds, done)
      end
    end

    (servers * philosophers).times { done.receive }
    puts "done: servers=#{servers} philosophers=#{philosophers} rounds=#{rounds}"
  end
end

servers = 2
philosophers = 5
rounds = 3

OptionParser.parse do |parser|
  parser.banner = "Usage: crystal run dining_philosophers.cr -- [options]"

  parser.on("--servers N", "Number of independent tuple-space servers (default: 2)") { |n| servers = n.to_i }
  parser.on("--philosophers N", "Philosophers per server (default: 5)") { |n| philosophers = n.to_i }
  parser.on("--rounds N", "Rounds per philosopher (default: 3)") { |n| rounds = n.to_i }
  parser.on("-h", "--help", "Show help") { puts parser; exit(0) }
end

Chapter9Dining.run(servers, philosophers, rounds)
