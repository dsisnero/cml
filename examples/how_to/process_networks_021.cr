# process_networks_021.cr
# Extracted from: how_to.md
# Section: process_networks
# Lines: 661-835
#
# ----------------------------------------------------------

# Dummy definitions for example compilation
def run_process(cmd : String) : Bool
  true
end

def file_status(path : String) : Time?
  Time.utc
end

def get_mtime(path : String) : Time
  Time.utc
end

def parse_makefile(content : String) : Array(BuildSystem::Rule)
  [] of BuildSystem::Rule
end

def make_graph(signal_ch, rules)
  # Dummy implementation
  CML.mchannel(BuildSystem::Stamp).port
end

require "../../src/cml"
require "../../src/cml/multicast"

module BuildSystem
  # Stamp represents build result: either timestamp or error
  struct StampError; end

  ERROR = StampError.new
  alias Stamp = Time | StampError

  # Rule from makefile
  record Rule,
    target : String,
    antecedents : Array(String),
    action : String

  # Create an internal node (has dependencies)
  def self.make_node(target : String, antecedents : Array(CML::Multicast::Port(Stamp)), action : String) : CML::Multicast::Chan(Stamp)
    status = CML.mchannel(Stamp)

    CML.spawn do
      loop do
        # CRITICAL: Wait for ALL antecedents before proceeding
        # This is where parallelism happens - while this node waits,
        # other independent nodes can run
        stamps = antecedents.map { |port| CML.sync(port.recv_evt) }

        # Find most recent timestamp (or error)
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
          # Error in dependency - propagate immediately
          status.multicast(ERROR)
        when Time
          # Check if rebuild is needed
          if obj_time = file_status(target)
            if obj_time < max_stamp
              # Dependency is newer - rebuild
              run_build_action(target, action, status)
            else
              # Up to date - just forward timestamp
              status.multicast(obj_time)
            end
          else
            # File doesn't exist - must build
            run_build_action(target, action, status)
          end
        end
      end
    end

    status
  end

  # Create a leaf node (no dependencies, just checks file)
  def self.make_leaf(signal_ch : CML::Multicast::Chan(Nil), target : String, action : String?)
    start = signal_ch.port
    status = CML.mchannel(Stamp)

    CML.spawn do
      loop do
        # Wait for controller's start signal
        # All leaves start simultaneously - MAXIMUM PARALLELISM
        CML.sync(start.recv_evt)

        if action
          # Leaf with action (e.g., "generate header.h")
          run_build_action(target, action, status)
        else
          # Source file - just check timestamp
          status.multicast(get_mtime(target))
        end
      end
    end

    status
  end

  def self.run_build_action(target : String, action : String, status : CML::Multicast::Chan(Stamp))
    if run_process(action)
      status.multicast(get_mtime(target))
    else
      STDERR.puts "Error making \"#{target}\""
      status.multicast(ERROR)
    end
  end

  # Main controller
  def self.make(file : String) : Proc(Bool)
    req_ch = CML.channel(Nil)     # Request channel (trigger build)
    repl_ch = CML.channel(Bool)   # Reply channel (success/failure)
    signal_ch = CML.mchannel(Nil) # Multicast start signal

    # Parse makefile and build dependency graph
    content = File.read(file)
    parsed = parse_makefile(content)
    root_port = make_graph(signal_ch, parsed)

    # Controller thread
    CML.spawn do
      loop do
        # Wait for build request
        CML.sync(req_ch.recv_evt)

        # BROADCAST: Signal all leaves to start simultaneously
        # This is where the parallelism begins
        signal_ch.multicast(nil)

        # Wait for final result from root node
        result = CML.sync(root_port.recv_evt)

        # Send reply to caller
        case result
        when Time
          CML.sync(repl_ch.send_evt(true))
        else
          CML.sync(repl_ch.send_evt(false))
        end
      end
    end

    # Return build function
    -> : Bool {
      CML.sync(req_ch.send_evt(nil))
      CML.sync(repl_ch.recv_evt)
    }
  end
end

# Example makefile content
makefile_content = <<-MAKEFILE
program : main.o util.o
    gcc -o program main.o util.o

main.o : main.c util.h
    gcc -c main.c

util.o : util.c util.h
    gcc -c util.c

util.h : generate_header.sh
    sh generate_header.sh
MAKEFILE

# Usage
File.write("example.makefile", makefile_content)

begin
  build = BuildSystem.make("example.makefile")

  # Trigger build - this runs ALL possible tasks in parallel
  success = build.call

  if success
    puts "Build successful! All tasks completed with maximum parallelism."
  else
    puts "Build failed. Check error messages above."
  end
ensure
  File.delete("example.makefile") if File.exists?("example.makefile")
end
