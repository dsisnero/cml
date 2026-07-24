{% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 || (flag?(:preview_mt) && flag?(:execution_context)) %}
  require "fiber/execution_context"
{% end %}

module CML
  {% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 || (flag?(:preview_mt) && flag?(:execution_context)) %}
    # Execution context wrapper for explicitly parallel CML work.
    #
    # `capacity` is the maximum parallelism, not a number of permanently
    # dedicated threads. Shared mutable state used by these fibers must be
    # synchronized with a `Mutex` or `Atomic`.
    class ExecutionContext < Fiber::ExecutionContext::Parallel
      def initialize(name : String = "CML", capacity : Int32 = 1)
        super(name, capacity, hijack: false)
      end
    end
  {% else %}
    # Fallback context for builds without multithreaded execution contexts.
    # `spawn` uses the default scheduler and `wait` is a no-op.
    class ExecutionContext
      def initialize(@name : String = "CML", @capacity : Int32 = 1)
      end

      def spawn(&block : -> Nil) : Fiber
        ::spawn { block.call }
      end

      def wait : Nil
      end
    end
  {% end %}
end
