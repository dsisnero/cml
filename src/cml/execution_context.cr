{% if flag?(:preview_mt) && flag?(:execution_context) %}
  require "fiber/execution_context"
{% end %}

module CML
  {% if flag?(:preview_mt) && flag?(:execution_context) %}
    # Execution context wrapper for running fibers in a dedicated context.
    # This delegates to Crystal's concurrent execution context.
    class ExecutionContext < Fiber::ExecutionContext::Concurrent
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
