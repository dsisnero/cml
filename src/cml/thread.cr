module CML
  module Thread
    # ThreadId - Thread Identity and Management (SML/NJ compatible)
    # Wraps Crystal's Fiber with CML-style thread identity and join events.
    class Id
      getter fiber : Fiber
      getter id : UInt64
      @exit_cvar : CVar
      @exited = AtomicFlag.new

      @@id_counter = Atomic(UInt64).new(0_u64)
      @@fiber_to_tid = {} of Fiber => Id
      @@tid_mtx = CML::Sync::Mutex.new

      protected def initialize(@fiber : Fiber, register : Bool = true)
        @id = @@id_counter.add(1)
        @exit_cvar = CVar.new
        if register
          @@tid_mtx.synchronize do
            @@fiber_to_tid[@fiber] = self
          end
        end
      end

      protected def self.make_for_fiber(fiber : Fiber) : Id
        tid = Id.new(fiber, register: false)
        @@tid_mtx.synchronize do
          @@fiber_to_tid[fiber] = tid
        end
        tid
      end

      def mark_exited
        return if @exited.get
        @exited.set(true)
        @exit_cvar.set!
        @@tid_mtx.synchronize do
          @@fiber_to_tid.delete(@fiber)
        end
      end

      def exited? : Bool
        @exited.get
      end

      def same?(other : Id) : Bool
        @id == other.id
      end

      def <=>(other : Id) : Int32
        @id <=> other.id
      end

      def hash : UInt64
        @id
      end

      def to_s(io : IO) : Nil
        io << "ThreadId(" << @id << ")"
      end

      def to_s : String
        "ThreadId(#{@id})"
      end

      def join_evt : Event(Nil)
        JoinEvent.new(self)
      end

      def self.for_fiber(fiber : Fiber) : Id?
        @@tid_mtx.synchronize do
          @@fiber_to_tid[fiber]?
        end
      end

      def self.current : Id
        fiber = Fiber.current
        existing = @@tid_mtx.synchronize do
          @@fiber_to_tid[fiber]?
        end
        return existing if existing
        make_for_fiber(fiber)
      end

      protected def make_join_poll : Proc(EventStatus(Nil))
        tid = self
        cvar = @exit_cvar

        -> : EventStatus(Nil) {
          if tid.exited?
            Enabled(Nil).new(priority: 0, value: nil)
          else
            cvar.poll
          end
        }
      end
    end

    class JoinEvent < Event(Nil)
      @poll_fn : Proc(EventStatus(Nil))

      def initialize(@tid : Id)
        @poll_fn = @tid.make_join_poll
      end

      def poll : EventStatus(Nil)
        @poll_fn.call
      end

      protected def force_impl : EventGroup(Nil)
        BaseGroup(Nil).new(@poll_fn)
      end
    end

    class Exit < Exception
      def initialize
        super("Thread exit")
      end
    end

    # Thread property - thread-local storage with lazy initialization
    class Prop(T)
      @values = {} of UInt64 => T
      @init_fn : -> T
      @mtx = CML::Sync::Mutex.new

      def initialize(&@init_fn : -> T)
      end

      private def fiber_key : UInt64
        Fiber.current.object_id
      end

      def clear
        key = fiber_key
        @mtx.synchronize do
          @values.delete(key)
        end
      end

      def get : T
        key = fiber_key
        @mtx.synchronize do
          @values[key]? || begin
            val = @init_fn.call
            @values[key] = val
            val
          end
        end
      end

      def peek : T?
        key = fiber_key
        @mtx.synchronize do
          @values[key]?
        end
      end

      def set(value : T)
        key = fiber_key
        @mtx.synchronize do
          @values[key] = value
        end
      end
    end

    # Thread flag - simple boolean thread-local storage
    class Flag
      @values = {} of UInt64 => Bool
      @mtx = CML::Sync::Mutex.new

      def initialize
      end

      private def fiber_key : UInt64
        Fiber.current.object_id
      end

      def get : Bool
        key = fiber_key
        @mtx.synchronize do
          @values[key]? || false
        end
      end

      def set(value : Bool)
        key = fiber_key
        @mtx.synchronize do
          @values[key] = value
        end
      end
    end
  end
end
