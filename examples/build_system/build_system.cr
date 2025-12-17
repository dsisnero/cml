# Build System Example
# ====================
# A parallel build system using CML, based on Chapter 7 of
# "Concurrent Programming in ML" by John H. Reppy.
#
# This demonstrates how CML can be used as a concurrent shell language
# for managing multiple independent tasks (like compiling files).
#
# The system translates a makefile into a dataflow network:
# - Nodes represent objects (files to build)
# - Edges represent dependencies (multicast channels)
# - Messages carry timestamps or errors

require "../../src/cml"
require "../../src/cml/multicast"

module BuildSystem
  # Stamp represents the result of checking/building an object
  # Either a timestamp or an error indicator
  struct StampError
  end

  ERROR = StampError.new

  alias Stamp = Time | StampError

  # Rule represents a single rule from the makefile
  record Rule,
    target : String,
    antecedents : Array(String),
    action : String

  # ParsedMakefile contains the root target and all rules
  record ParsedMakefile,
    root : String,
    rules : Array(Rule)

  # NodeState during graph construction
  enum NodeMark
    UNDEF
    MARKED
    DEFINED
  end

  # Get modification time of a file, or ERROR if it doesn't exist
  def self.get_mtime(obj_name : String) : Stamp
    if File.exists?(obj_name)
      File.info(obj_name).modification_time
    else
      ERROR
    end
  end

  # Check if a file exists and return its modification time
  def self.file_status(path : String) : Time?
    if File.exists?(path)
      File.info(path).modification_time
    end
  end

  # Run a shell command and return true if successful
  def self.run_process(prog : String) : Bool
    result = Process.run(
      "sh",
      args: ["-c", prog],
      output: Process::Redirect::Inherit,
      error: Process::Redirect::Inherit
    )
    result.success?
  rescue
    false
  end

  # Create a thread for an internal node in the dependency graph.
  # Takes the target name, list of antecedent multicast ports, and the action.
  # Returns the multicast channel for sending status to successors.
  def self.make_node(target : String, antecedents : Array(CML::Multicast::Port(Stamp)), action : String) : CML::Multicast::Chan(Stamp)
    status = CML.mchannel(Stamp)

    spawn(name: "node:#{target}") do
      loop do
        # Wait for all antecedents to send their stamps
        stamps = antecedents.map { |port| CML.sync(port.recv_evt) }

        # Find the maximum stamp (most recent time), or ERROR if any failed
        max_stamp = stamps.reduce(Time::UNIX_EPOCH.as(Stamp)) do |acc, stamp|
          case stamp
          when StampError then break ERROR.as(Stamp)
          when Time
            case acc
            when Time       then stamp > acc ? stamp : acc
            when StampError then ERROR
            else                 stamp
            end
          else
            acc
          end
        end

        case max_stamp
        when StampError
          # Propagate error
          status.multicast(ERROR)
        when Time
          # Helper to run action and notify result
          do_action = -> {
            if run_process(action)
              status.multicast(get_mtime(target))
            else
              STDERR.puts "Error making \"#{target}\""
              status.multicast(ERROR)
            end
          }

          # Check if we need to rebuild
          if obj_time = file_status(target)
            # File exists - check if it's older than antecedents
            if obj_time < max_stamp
              do_action.call
            else
              # Object is up to date
              status.multicast(obj_time)
            end
          else
            # File doesn't exist - need to build it
            do_action.call
          end
        end
      end
    end

    status
  end

  # Create a thread for a leaf node in the dependency graph.
  # Takes the signal channel from controller, target name, and optional action.
  # Returns the multicast channel for sending status to successors.
  def self.make_leaf(signal_ch : CML::Multicast::Chan(Nil), target : String, action : String?)
    # Each leaf gets its own port from the signal channel
    start = signal_ch.port
    status = CML.mchannel(Stamp)

    # Create the doAction function based on whether there's an action
    do_action = if act = action
                  -> { run_process(act) }
                else
                  -> { true }
                end

    spawn(name: "leaf:#{target}") do
      loop do
        # Wait for signal from controller
        CML.sync(start.recv_evt)

        # Run action and notify
        if do_action.call
          status.multicast(get_mtime(target))
        else
          STDERR.puts "Error making \"#{target}\""
          status.multicast(ERROR)
        end
      end
    end

    status
  end

  # Build the dependency graph from parsed makefile
  # Returns the multicast port for the root node
  def self.make_graph(signal_ch : CML::Multicast::Chan(Nil), parsed : ParsedMakefile) : CML::Multicast::Port(Stamp)
    # Table mapping object names to their state/channels
    # nil = undefined leaf, NodeMark::UNDEF with Rule = undefined internal node
    # NodeMark::MARKED = being processed, MChan = defined
    table = {} of String => {NodeMark, Rule?, CML::Multicast::Chan(Stamp)?}

    # Initialize table with all rules as undefined internal nodes
    parsed.rules.each do |rule|
      table[rule.target] = {NodeMark::UNDEF, rule, nil}
    end

    # Graph builder helper class to allow recursive calls
    graph_builder = GraphBuilder.new(signal_ch, table)

    # Process all rules
    parsed.rules.each do |rule|
      graph_builder.ins_nd(rule.target)
    end

    # Return port for root node
    root_ch = table[parsed.root]?
    raise "Root node not found" unless root_ch
    _, _, ch = root_ch
    raise "Root channel not created" unless ch
    ch.port
  end

  # Helper class for building the dependency graph
  class GraphBuilder
    @signal_ch : CML::Multicast::Chan(Nil)
    @table : Hash(String, {NodeMark, Rule?, CML::Multicast::Chan(Stamp)?})

    def initialize(@signal_ch, @table)
    end

    # Add a leaf node (file without a rule)
    def add_leaf(target : String) : CML::Multicast::Chan(Stamp)
      ch = BuildSystem.make_leaf(@signal_ch, target, nil)
      @table[target] = {NodeMark::DEFINED, nil, ch}
      ch
    end

    # Add a node from a rule
    # If the rule has no antecedents, create a leaf node with the action
    # Otherwise, create an internal node
    def add_nd(rule : Rule) : CML::Multicast::Chan(Stamp)
      if rule.antecedents.empty?
        # No antecedents - this is a leaf with an action
        ch = BuildSystem.make_leaf(@signal_ch, rule.target, rule.action)
        @table[rule.target] = {NodeMark::DEFINED, rule, ch}
        ch
      else
        # Has antecedents - this is an internal node
        # Mark as being processed (cycle detection)
        @table[rule.target] = {NodeMark::MARKED, rule, nil}

        # Process all antecedents first
        antecedent_chans = rule.antecedents.map do |ant|
          ch = ins_nd(ant)
          raise "Failed to create channel for #{ant}" unless ch
          ch.port
        end

        # Create the node
        ch = BuildSystem.make_node(rule.target, antecedent_chans, rule.action)
        @table[rule.target] = {NodeMark::DEFINED, rule, ch}
        ch
      end
    end

    # Insert a node into the graph
    def ins_nd(target : String) : CML::Multicast::Chan(Stamp)?
      entry = @table[target]?

      if entry.nil?
        # Undefined leaf - add it
        add_leaf(target)
      else
        mark, rule, ch = entry
        case mark
        when NodeMark::DEFINED
          # Already defined
          ch
        when NodeMark::MARKED
          # Cycle detected!
          raise "Cycle detected in dependency graph at #{target}"
        when NodeMark::UNDEF
          # Undefined internal node
          if r = rule
            add_nd(r)
          else
            add_leaf(target)
          end
        else
          nil # ameba:disable Lint/ElseNil
        end
      end
    end
  end

  # Parse a simple makefile
  # Format:
  #   target : dep1 dep2 ...
  #       action
  def self.parse_makefile(content : String) : ParsedMakefile
    rules = [] of Rule
    lines = content.lines.map(&.chomp)

    i = 0
    while i < lines.size
      line = lines[i].strip

      # Skip blank lines
      if line.empty?
        i += 1
        next
      end

      # Skip comments
      if line.starts_with?("#")
        i += 1
        next
      end

      # Parse dependency line: target : dep1 dep2 ...
      unless line.includes?(":")
        raise "Invalid makefile syntax at line #{i + 1}: expected dependency line"
      end

      parts = line.split(":", limit: 2)
      target = parts[0].strip
      deps = parts[1]?.try(&.split).try(&.map(&.strip).reject(&.empty?)) || [] of String

      # Next line should be the action (indented)
      i += 1
      if i >= lines.size
        raise "Missing action for target #{target}"
      end

      action_line = lines[i]
      unless action_line.starts_with?("\t") || action_line.starts_with?("  ")
        raise "Missing action for target #{target}"
      end

      action = action_line.strip

      rules << Rule.new(target: target, antecedents: deps, action: action)
      i += 1
    end

    if rules.empty?
      raise "Empty makefile"
    end

    # First rule defines the root
    ParsedMakefile.new(root: rules.first.target, rules: rules)
  end

  # Main make function
  # Takes a makefile filename and returns a function for rebuilding the system
  def self.make(file : String) : Proc(Bool)
    req_ch = CML.channel(Nil)
    repl_ch = CML.channel(Bool)
    signal_ch = CML.mchannel(Nil)

    # Parse makefile and build graph
    content = File.read(file)
    parsed = parse_makefile(content)
    root_port = make_graph(signal_ch, parsed)

    # Controller thread
    spawn(name: "controller") do
      loop do
        # Wait for request
        CML.sync(req_ch.recv_evt)

        # Signal all leaves to start
        signal_ch.multicast(nil)

        # Wait for result from root
        result = CML.sync(root_port.recv_evt)

        # Send reply
        case result
        when Time
          CML.sync(repl_ch.send_evt(true))
        else
          CML.sync(repl_ch.send_evt(false))
        end
      end
    end

    # Return function to trigger builds
    -> : Bool {
      CML.sync(req_ch.send_evt(nil))
      CML.sync(repl_ch.recv_evt)
    }
  end
end

# Example usage when run directly
if PROGRAM_NAME.includes?("build_system")
  # Check for makefile argument
  if ARGV.empty?
    puts "Usage: #{PROGRAM_NAME} <makefile>"
    puts ""
    puts "This is a parallel build system using CML."
    puts "It demonstrates concurrent management of independent tasks."
    exit 1
  end

  makefile = ARGV[0]

  unless File.exists?(makefile)
    STDERR.puts "Error: Makefile '#{makefile}' not found"
    exit 1
  end

  puts "Building from #{makefile}..."

  begin
    build = BuildSystem.make(makefile)

    # Allow fibers to initialize
    Fiber.yield

    success = build.call

    if success
      puts "Build successful!"
      exit 0
    else
      puts "Build failed!"
      exit 1
    end
  rescue ex
    STDERR.puts "Error: #{ex.message}"
    exit 1
  end
end
