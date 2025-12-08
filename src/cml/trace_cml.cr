# src/cml/trace_cml.cr
#
# Port of SML/NJ CML trace-cml.sml to Crystal
# COPYRIGHT (c) 1992 AT&T Bell Laboratories
#
# This module provides debugging support in the form of mechanisms
# to control debugging output, and to monitor fiber termination.
# Adapted from Cliff Krumvieda's utility for tracing CML programs.
#
# It provides three facilities:
# - Trace modules, for controlling debugging output
# - Fiber watching, for detecting fiber termination
# - A mechanism for reporting uncaught exceptions on a per-fiber basis
#
# SML signature:
#   structure TraceCML : TRACE_CML =
#     sig
#       datatype trace_to = TraceToOut | TraceToErr | TraceToNull
#                         | TraceToFile of string | TraceToStream of ...
#       exception NoSuchModule
#
#       type trace_module
#       val traceRoot : trace_module
#       val traceModule : trace_module * string -> trace_module
#       val nameOf : trace_module -> string
#       val moduleOf : string -> trace_module
#       val traceOn : trace_module -> unit
#       val traceOff : trace_module -> unit
#       val traceOnly : trace_module -> unit
#       val amTracing : trace_module -> bool
#       val status : trace_module -> (trace_module * bool) list
#       val setTraceFile : trace_to -> unit
#       val trace : trace_module * (unit -> string list) -> unit
#
#       val watch : string * thread_id -> unit
#       val unwatch : thread_id -> unit
#
#       val setUncaughtFn : (thread_id * exn -> unit) -> unit
#       val setHandleFn : (thread_id * exn -> bool) -> unit
#       val resetUncaughtFn : unit -> unit
#     end

require "../cml"
require "../ivar"
require "./mailbox"

module CML
  module TraceCML
    # Where to direct trace output to
    enum TraceTo
      Out
      Err
      Null
      # File and Stream handled separately with IO
    end

    class NoSuchModule < Exception
      def initialize(name : String)
        super("No such trace module: #{name}")
      end
    end

    # Trace module for hierarchical trace control
    class TraceModule
      getter full_name : String
      getter label : String
      property tracing : Bool
      getter children : Array(TraceModule)
      getter parent : TraceModule?

      def initialize(@full_name : String, @label : String, @tracing : Bool = false, @parent : TraceModule? = nil)
        @children = [] of TraceModule
      end

      # Find or create a child module
      def child(name : String) : TraceModule
        # Check if child already exists
        existing = @children.find { |c| c.label == name }
        return existing if existing

        # Create new child
        child_full_name = @full_name == "/" ? "/#{name}" : "#{@full_name}/#{name}"
        child = TraceModule.new(child_full_name, name, @tracing, self)
        @children << child
        child
      end

      # Turn tracing on for this module and all descendants
      def trace_on!
        @tracing = true
        @children.each(&.trace_on!)
      end

      # Turn tracing off for this module and all descendants
      def trace_off!
        @tracing = false
        @children.each(&.trace_off!)
      end

      # Turn tracing on for this module only (not descendants)
      def trace_only!
        @tracing = true
      end

      # Check if this module is being traced
      def tracing? : Bool
        @tracing
      end

      # Get status of this module and all descendants
      def status : Array(Tuple(TraceModule, Bool))
        result = [{self, @tracing}] of Tuple(TraceModule, Bool)
        @children.each do |child|
          result.concat(child.status)
        end
        result
      end
    end

    # The root trace module
    @@trace_root : TraceModule = TraceModule.new("/", "", false)

    # Current trace destination
    @@trace_dst : TraceTo = TraceTo::Out
    @@trace_stream : IO? = nil
    @@trace_cleanup : Proc(Nil) = -> { }
    @@trace_mutex = Mutex.new

    # Get the root trace module
    def self.trace_root : TraceModule
      @@trace_root
    end

    # Create or get a trace module
    # Equivalent to SML's: fun traceModule (parent, name) = ...
    def self.trace_module(parent : TraceModule, name : String) : TraceModule
      parent.child(name)
    end

    # Get the name of a trace module
    # Equivalent to SML's: fun nameOf (TM{full_name, ...}) = full_name
    def self.name_of(tm : TraceModule) : String
      tm.full_name
    end

    # Find a module by path string
    # Equivalent to SML's: fun moduleOf name = ...
    def self.module_of(name : String) : TraceModule
      parts = name.split('/').reject(&.empty?)
      current = @@trace_root

      parts.each do |part|
        found = current.children.find { |c| c.label == part }
        raise NoSuchModule.new(name) unless found
        current = found
      end

      current
    end

    # Find a module by path string, returning nil if not found
    def self.module_of?(name : String) : TraceModule?
      parts = name.split('/').reject(&.empty?)
      current = @@trace_root

      parts.each do |part|
        found = current.children.find { |c| c.label == part }
        return unless found
        current = found
      end

      current
    end

    # Turn tracing on for a module and its descendants
    def self.trace_on(tm : TraceModule)
      tm.trace_on!
    end

    # Turn tracing off for a module and its descendants
    def self.trace_off(tm : TraceModule)
      tm.trace_off!
    end

    # Turn tracing on for a module only
    def self.trace_only(tm : TraceModule)
      tm.trace_only!
    end

    # Check if a module is being traced
    def self.am_tracing(tm : TraceModule) : Bool
      tm.tracing?
    end

    # Get status of all modules under a root
    def self.status(root : TraceModule) : Array(Tuple(TraceModule, Bool))
      root.status
    end

    # Set where trace output goes
    def self.set_trace_file(to : TraceTo)
      @@trace_mutex.synchronize do
        @@trace_cleanup.call
        @@trace_dst = to
        @@trace_stream = nil
        @@trace_cleanup = -> { }
      end
    end

    # Set trace output to a file
    def self.set_trace_file(filename : String)
      @@trace_mutex.synchronize do
        @@trace_cleanup.call
        begin
          file = File.open(filename, "w")
          @@trace_stream = file
          @@trace_cleanup = -> { file.close rescue nil; nil }
        rescue ex
          STDERR.puts "TraceCML: unable to open \"#{filename}\", redirecting to stdout"
          @@trace_dst = TraceTo::Out
          @@trace_stream = nil
          @@trace_cleanup = -> { }
        end
      end
    end

    # Set trace output to an IO stream
    def self.set_trace_stream(stream : IO)
      @@trace_mutex.synchronize do
        @@trace_cleanup.call
        @@trace_stream = stream
        @@trace_cleanup = -> { }
      end
    end

    # Internal trace print function
    private def self.trace_print(s : String)
      @@trace_mutex.synchronize do
        io = case
             when stream = @@trace_stream
               stream
             when @@trace_dst == TraceTo::Out
               STDOUT
             when @@trace_dst == TraceTo::Err
               STDERR
             when @@trace_dst == TraceTo::Null
               nil
             else
               STDOUT
             end

        if io
          io.print(s)
          io.flush
        end
      end
    end

    # Trace a message if the module is being traced
    # Equivalent to SML's: fun trace (TM{tracing, ...}, prFn) = ...
    def self.trace(tm : TraceModule, &block : -> Array(String))
      if tm.tracing?
        trace_print(block.call.join)
      end
    end

    # Trace with a simple string
    def self.trace(tm : TraceModule, msg : String)
      if tm.tracing?
        trace_print(msg)
      end
    end

    # =========================================
    # Fiber Watching
    # =========================================

    # Watcher module for fiber watching
    @@watcher : TraceModule = trace_module(@@trace_root, "FiberWatcher")

    # Watcher messages
    module WatcherMsg
      record Watch, fiber : Fiber, name : String, unwatch_ch : Chan(Nil)
      record Unwatch, fiber : Fiber, ack : IVar(Nil)
    end

    # Watcher mailbox
    @@watcher_mb = Mailbox(WatcherMsg::Watch | WatcherMsg::Unwatch).new
    @@watched_fibers = Hash(Fiber, Chan(Nil)).new
    @@watcher_started = Atomic(Bool).new(false)
    @@watcher_mutex = Mutex.new

    # Start the watcher server
    private def self.start_watcher
      return if @@watcher_started.swap(true)

      trace_on(@@watcher)

      spawn do
        loop do
          msg = @@watcher_mb.recv
          case msg
          when WatcherMsg::Watch
            @@watcher_mutex.synchronize do
              @@watched_fibers[msg.fiber] = msg.unwatch_ch
            end
          when WatcherMsg::Unwatch
            @@watcher_mutex.synchronize do
              if ch = @@watched_fibers.delete(msg.fiber)
                CML.sync(ch.send_evt(nil)) rescue nil
              end
            end
            msg.ack.fill(nil)
          end
        end
      end
    end

    # Watch a fiber for unexpected termination
    # Equivalent to SML's: fun watch (name, tid) = ...
    def self.watch(name : String, fiber : Fiber)
      start_watcher

      unwatch_ch = Chan(Nil).new

      spawn do
        @@watcher_mb.send(WatcherMsg::Watch.new(fiber, name, unwatch_ch))

        # Wait for either unwatch signal or fiber death
        # Note: Crystal doesn't have a direct joinEvt equivalent,
        # so we poll for fiber status
        loop do
          break if fiber.dead?

          # Check for unwatch signal with timeout
          select
          when CML.sync(CML.timeout(100.milliseconds))
            # Continue checking
          end
        end

        # If fiber died and wasn't unwatched, log warning
        @@watcher_mutex.synchronize do
          if @@watched_fibers.has_key?(fiber)
            trace(@@watcher) do
              ["WARNING! Watched fiber ", name, " has died.\n"]
            end
            @@watched_fibers.delete(fiber)
          end
        end
      end
    end

    # Stop watching a fiber
    # Equivalent to SML's: fun unwatch tid = ...
    def self.unwatch(fiber : Fiber)
      ack = IVar(Nil).new
      @@watcher_mb.send(WatcherMsg::Unwatch.new(fiber, ack))
      ack.read
    end

    # =========================================
    # Uncaught Exception Handling
    # =========================================

    alias ExceptionHandler = Proc(Fiber, Exception, Nil)
    alias ExceptionFilter = Proc(Fiber, Exception, Bool)

    @@default_handler : ExceptionHandler = ->(fiber : Fiber, ex : Exception) {
      raised_at = ex.backtrace?.try(&.last?) || ""
      msg = String.build do |io|
        io << "Fiber "
        io << fiber.name || "unnamed"
        io << " uncaught exception "
        io << ex.class.name
        io << " ["
        io << ex.message
        io << "]"
        io << " raised at " << raised_at unless raised_at.empty?
        io << "\n"
      end
      STDERR.print(msg)
      nil
    }

    @@exception_handlers = [] of ExceptionFilter
    @@exception_mutex = Mutex.new

    # Set the default uncaught exception action
    def self.set_uncaught_fn(handler : ExceptionHandler)
      @@exception_mutex.synchronize do
        @@default_handler = handler
      end
    end

    # Add an additional uncaught exception handler
    # If the handler returns true, no further action is taken
    def self.set_handle_fn(filter : ExceptionFilter)
      @@exception_mutex.synchronize do
        @@exception_handlers.unshift(filter)
      end
    end

    # Reset exception handling to defaults
    def self.reset_uncaught_fn
      @@exception_mutex.synchronize do
        @@default_handler = ->(fiber : Fiber, ex : Exception) {
          raised_at = ex.backtrace?.try(&.last?) || ""
          msg = String.build do |io|
            io << "Fiber "
            io << fiber.name || "unnamed"
            io << " uncaught exception "
            io << ex.class.name
            io << " ["
            io << ex.message
            io << "]"
            io << " raised at " << raised_at unless raised_at.empty?
            io << "\n"
          end
          STDERR.print(msg)
          nil
        }
        @@exception_handlers.clear
      end
    end

    # Handle an uncaught exception (called internally)
    def self.handle_exception(fiber : Fiber, ex : Exception)
      handlers = @@exception_mutex.synchronize { @@exception_handlers.dup }
      default = @@exception_mutex.synchronize { @@default_handler }

      # Try each handler in order
      handlers.each do |handler|
        begin
          return if handler.call(fiber, ex)
        rescue
          # Handler failed, continue to next
        end
      end

      # No handler handled it, use default
      begin
        default.call(fiber, ex)
      rescue
        # Default handler failed, print to stderr
        STDERR.puts "Exception in fiber #{fiber.name}: #{ex}"
      end
    end

    # Spawn a fiber with exception handling
    def self.spawn_traced(name : String? = nil, &block)
      fiber = spawn(name: name) do
        begin
          block.call
        rescue ex
          handle_exception(Fiber.current, ex)
        end
      end
      fiber
    end
  end
end