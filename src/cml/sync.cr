# Synchronization primitives compatibility.
#
# Crystal 1.21 enables execution contexts by default. Older Crystal versions
# use thread-safe Sync primitives only when the legacy execution-context flags
# are enabled. Otherwise, fall back to fiber-safe primitives.

{% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 || (compare_versions(Crystal::VERSION, "1.19.0") >= 0 && flag?(:preview_mt) && flag?(:execution_context)) %}
  require "sync/**"
{% end %}

module CML
  module Sync
    {% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 || (compare_versions(Crystal::VERSION, "1.19.0") >= 0 && flag?(:preview_mt) && flag?(:execution_context)) %}
      # Thread-safe primitives when multithreaded execution contexts are enabled.
      alias Mutex = ::Sync::Mutex
      alias ConditionVariable = ::Sync::ConditionVariable
      alias RWLock = ::Sync::RWLock
      alias Exclusive = ::Sync::Exclusive
      alias Shared = ::Sync::Shared

      # Type enum for mutex configuration
      alias Type = ::Sync::Type

      # Helper to create a mutex with optional type
      def self.mutex(type : Type = :checked) : Mutex
        Mutex.new(type)
      end

      # Helper to create a condition variable associated with a lock
      def self.condition_variable(lock : Mutex) : ConditionVariable
        ConditionVariable.new(lock)
      end
    {% else %}
      # Default fallback for builds without execution-context flags.
      class Mutex
        @mutex : ::Mutex

        def initialize(type : Type = :checked)
          @mutex = ::Mutex.new
        end

        def synchronize(& : -> U) : U forall U
          @mutex.synchronize { yield }
        end

        def lock
          @mutex.lock
        end

        def unlock
          @mutex.unlock
        end

        def try_lock : Bool
          @mutex.try_lock
        end
      end

      alias ConditionVariable = ::Thread::ConditionVariable

      # Simplified type enum for compatibility
      enum Type
        Unchecked
        Checked
        Reentrant
      end

      # RWLock, Exclusive, Shared are not available in standard library
      # Define placeholder types or use regular mutex
      # For simplicity, we'll use regular mutex for these
      class RWLock
        def initialize(@type : Type = :checked)
          @mutex = ::Mutex.new
        end

        def read_lock(& : -> U) : U forall U
          @mutex.synchronize { yield }
        end

        def write_lock(& : -> U) : U forall U
          @mutex.synchronize { yield }
        end
      end

      class Exclusive(T)
        def initialize(@value : T, @type : Type = :checked)
          @mutex = ::Mutex.new
        end

        def synchronize(& : -> U) : U forall U
          @mutex.synchronize { yield }
        end

        def get : T
          @mutex.synchronize { @value }
        end

        def set(value : T) : T
          @mutex.synchronize { @value = value }
        end
      end

      class Shared(T)
        def initialize(@value : T, @type : Type = :checked)
          @mutex = ::Mutex.new
        end

        def read(& : T -> U) : U forall U
          @mutex.synchronize { yield @value }
        end

        def write(& : T -> U) : U forall U
          @mutex.synchronize { yield @value }
        end
      end

      # Helper to create a mutex with optional type (type ignored for regular Mutex)
      def self.mutex(type : Type = :checked) : Mutex
        Mutex.new
      end

      # Helper to create a condition variable
      # Note: Thread::ConditionVariable doesn't associate with lock at creation time
      def self.condition_variable(lock : Mutex) : ConditionVariable
        ConditionVariable.new
      end
    {% end %}
  end
end
