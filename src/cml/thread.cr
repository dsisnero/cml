module CML
  module Thread
    # Custodian - Resource controller for threads.
    # A thread is suspended when all of its controlling custodians are shut down.
    class Custodian
      getter id : UInt64
      getter parent : Custodian?

      @shutdown = AtomicFlag.new
      @threads = Set(Id).new
      @children = Set(Custodian).new
      @mtx = CML::Sync::Mutex.new

      @@id_counter = Atomic(UInt64).new(0_u64)

      def initialize(@parent : Custodian? = nil)
        @id = @@id_counter.add(1)
        @parent.try(&.add_child(self))
      end

      def ==(other : Custodian)
        @id == other.id
      end

      def hash : UInt64
        @id
      end

      def shutdown? : Bool
        @shutdown.get
      end

      def shutdown_all : Nil
        threads = [] of Id
        children = [] of Custodian

        @mtx.synchronize do
          return if @shutdown.get
          @shutdown.set(true)
          threads = @threads.to_a
          children = @children.to_a
        end

        children.each(&.shutdown_all)
        threads.each(&.on_custodian_shutdown(self))
      end

      protected def add_thread(tid : Id) : Nil
        @mtx.synchronize { @threads.add(tid) }
      end

      protected def remove_thread(tid : Id) : Nil
        @mtx.synchronize { @threads.delete(tid) }
      end

      protected def add_child(child : Custodian) : Nil
        @mtx.synchronize { @children.add(child) }
      end
    end

    @@custodian_mtx = CML::Sync::Mutex.new
    @@root_custodian = Custodian.new(nil)
    @@fiber_to_custodian = {} of Fiber => Custodian
    @@fiber_local_cleaners = [] of Fiber -> Nil
    @@fiber_local_cleaners_mtx = CML::Sync::Mutex.new

    def self.root_custodian : Custodian
      @@root_custodian
    end

    def self.current_custodian : Custodian
      fiber = Fiber.current
      @@custodian_mtx.synchronize do
        @@fiber_to_custodian[fiber]? || @@root_custodian
      end
    end

    def self.set_fiber_custodian(fiber : Fiber, custodian : Custodian) : Nil
      @@custodian_mtx.synchronize do
        @@fiber_to_custodian[fiber] = custodian
      end
    end

    def self.clear_fiber_custodian(fiber : Fiber) : Nil
      @@custodian_mtx.synchronize do
        @@fiber_to_custodian.delete(fiber)
      end
    end

    protected def self.register_fiber_local_cleaner(&block : Fiber -> Nil) : Nil
      @@fiber_local_cleaners_mtx.synchronize do
        @@fiber_local_cleaners << block
      end
    end

    protected def self.cleanup_fiber_locals(fiber : Fiber) : Nil
      cleaners = @@fiber_local_cleaners_mtx.synchronize do
        @@fiber_local_cleaners.dup
      end
      cleaners.each(&.call(fiber))
    end

    def self.with_custodian(custodian : Custodian, &block : -> T) : T forall T
      fiber = Fiber.current
      previous = @@custodian_mtx.synchronize do
        old = @@fiber_to_custodian[fiber]? || @@root_custodian
        @@fiber_to_custodian[fiber] = custodian
        old
      end

      begin
        block.call
      ensure
        @@custodian_mtx.synchronize do
          @@fiber_to_custodian[fiber] = previous
        end
      end
    end

    # ThreadId - Thread Identity and Management (SML/NJ compatible)
    # Wraps Crystal's Fiber with CML-style thread identity and join events.
    class Id
      getter fiber : Fiber
      getter id : UInt64
      @exit_cvar : CVar
      @exited = AtomicFlag.new
      @killed = AtomicFlag.new
      @suspended = AtomicFlag.new

      @controllers = Set(Custodian).new
      @controller_mtx = CML::Sync::Mutex.new
      @yoked_dependents = Set(Id).new
      @yoke_mtx = CML::Sync::Mutex.new

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
        CML.trace "Thread::Id.mark_exited", @id, @fiber, @fiber.dead?, tag: "thread"
        return if @exited.get
        @exited.set(true)
        @exit_cvar.set!
        controllers = @controller_mtx.synchronize { @controllers.to_a }
        controllers.each(&.remove_thread(self))
        Thread.cleanup_fiber_locals(@fiber)
        Thread.clear_fiber_custodian(@fiber)
        @@tid_mtx.synchronize do
          @@fiber_to_tid.delete(@fiber)
        end
      end

      def exited? : Bool
        @exited.get
      end

      def killed? : Bool
        @killed.get
      end

      def suspended? : Bool
        @suspended.get
      end

      def kill : Nil
        return if @killed.get
        @killed.set(true)
        CML.cancel_transactions_for(@fiber)
        @fiber.enqueue unless @fiber.dead?
      end

      def ==(other : Id)
        @id == other.id
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

      def add_controller(custodian : Custodian) : Nil
        added = false
        @controller_mtx.synchronize do
          unless @controllers.includes?(custodian)
            @controllers.add(custodian)
            added = true
          end
        end
        return unless added

        custodian.add_thread(self)
        dependents = @yoke_mtx.synchronize { @yoked_dependents.to_a }
        dependents.each(&.add_controller(custodian))
      end

      def on_custodian_shutdown(_custodian : Custodian) : Nil
        all_shutdown = @controller_mtx.synchronize do
          !@controllers.empty? && @controllers.all?(&.shutdown?)
        end
        suspend! if all_shutdown
      end

      def suspend! : Nil
        return if @suspended.get || @exited.get
        @suspended.set(true)
        CML.cancel_transactions_for(@fiber)
        @fiber.enqueue unless @fiber.dead?
      end

      def resume! : Nil
        return if @exited.get
        active_controller = @controller_mtx.synchronize do
          @controllers.any? { |cust| !cust.shutdown? }
        end
        return unless active_controller
        @suspended.set(false)
        @fiber.enqueue unless @fiber.dead?
        dependents = @yoke_mtx.synchronize { @yoked_dependents.to_a }
        dependents.each(&.resume!)
      end

      def resume_with_custodian(custodian : Custodian) : Nil
        add_controller(custodian)
        resume!
      end

      def resume_with_thread(source : Id) : Nil
        source.add_yoked_dependent(self)
        source.controllers_snapshot.each { |cust| add_controller(cust) }
        resume!
      end

      def add_yoked_dependent(dep : Id) : Nil
        return if dep.id == @id
        @yoke_mtx.synchronize { @yoked_dependents.add(dep) }
      end

      def controllers_snapshot : Array(Custodian)
        @controller_mtx.synchronize { @controllers.to_a }
      end

      def wait_if_suspended : Nil
        while @suspended.get && !@killed.get && !@exited.get
          Fiber.suspend
        end
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

    class Killed < Exception
      def initialize
        super("Thread killed")
      end
    end

    # Thread property - thread-local storage with lazy initialization.
    class Prop(T)
      @values = {} of Fiber => T
      @init_fn : -> T
      @mtx = CML::Sync::Mutex.new

      def initialize(&@init_fn : -> T)
        Thread.register_fiber_local_cleaner do |fiber|
          remove_fiber(fiber)
        end
      end

      private def current_fiber : Fiber
        Fiber.current
      end

      private def prune_dead_fibers : Nil
        @values.reject! { |fiber, _| fiber.dead? }
      end

      protected def remove_fiber(fiber : Fiber) : Nil
        @mtx.synchronize do
          @values.delete(fiber)
        end
      end

      def clear
        fiber = current_fiber
        @mtx.synchronize do
          prune_dead_fibers
          @values.delete(fiber)
        end
      end

      def get : T
        fiber = current_fiber
        @mtx.synchronize do
          prune_dead_fibers
          @values[fiber]? || begin
            val = @init_fn.call
            @values[fiber] = val
            val
          end
        end
      end

      def peek : T?
        fiber = current_fiber
        @mtx.synchronize do
          prune_dead_fibers
          @values[fiber]?
        end
      end

      def set(value : T)
        fiber = current_fiber
        @mtx.synchronize do
          prune_dead_fibers
          @values[fiber] = value
        end
      end
    end

    # Thread flag - simple boolean thread-local storage.
    class Flag
      @values = {} of Fiber => Bool
      @mtx = CML::Sync::Mutex.new

      def initialize
        Thread.register_fiber_local_cleaner do |fiber|
          remove_fiber(fiber)
        end
      end

      private def current_fiber : Fiber
        Fiber.current
      end

      private def prune_dead_fibers : Nil
        @values.reject! { |fiber, _| fiber.dead? }
      end

      protected def remove_fiber(fiber : Fiber) : Nil
        @mtx.synchronize do
          @values.delete(fiber)
        end
      end

      def get : Bool
        fiber = current_fiber
        @mtx.synchronize do
          prune_dead_fibers
          @values[fiber]? || false
        end
      end

      def set(value : Bool)
        fiber = current_fiber
        @mtx.synchronize do
          prune_dead_fibers
          @values[fiber] = value
        end
      end

      def clear : Nil
        fiber = current_fiber
        @mtx.synchronize do
          prune_dead_fibers
          @values.delete(fiber)
        end
      end
    end
  end
end
