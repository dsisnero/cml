module CML
  # Execution context wrapper for running fibers in a dedicated context.
  # This currently delegates to Crystal's concurrent execution context and
  # provides a named container for future CML-aware scheduling.
  class ExecutionContext < Fiber::ExecutionContext::Concurrent
    def initialize(name : String = "CML", capacity : Int32 = 1)
      super(name, capacity, hijack: false)
    end
  end
end
