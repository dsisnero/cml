module CML
  module Process
    # Event that runs a system command and completes when the process exits.
    # Uses a nack watcher to allow terminating the process when a different branch wins a choice.
    class SystemCommandEvent < Event(::Process::Status)
      @command : String
      @nack_evt : Event(Nil)?
      @ready = AtomicFlag.new
      @cancel_flag = AtomicFlag.new
      @result = Slot(Exception | ::Process::Status).new
      @started = false
      @start_mtx = CML::Sync::Mutex.new

      def initialize(@command, @nack_evt = nil)
      end

      def poll : EventStatus(::Process::Status)
        if @ready.get
          return Enabled(::Process::Status).new(priority: 0, value: fetch_result)
        end

        Blocked(::Process::Status).new do |tid, next_fn|
          start_once(tid)
          next_fn.call
        end
      end

      protected def force_impl : EventGroup(::Process::Status)
        BaseGroup(::Process::Status).new(-> : EventStatus(::Process::Status) { poll })
      end

      private def start_once(tid : TransactionId)
        should_start = false

        @start_mtx.synchronize do
          unless @started
            @started = true
            should_start = true
          end
        end

        return unless should_start

        proc_chan = ::Channel(::Process).new(1)

        start_nack_watcher(proc_chan, tid)

        ::spawn do
          begin
            proc = ::Process.new(@command, shell: true)
            proc_chan.send(proc)
            status = proc.wait
            deliver(status, tid)
          rescue ex : Exception
            deliver(ex, tid)
          ensure
            proc_chan.close unless proc_chan.closed?
          end
        end
      end

      private def start_nack_watcher(proc_chan : ::Channel(::Process), tid : TransactionId)
        if nack = @nack_evt
          ::spawn do
            CML.sync(nack)
            @cancel_flag.set(true)
            tid.try_cancel
            begin
              proc = proc_chan.receive
              proc.terminate
            rescue Channel::ClosedError
            end
          end
        end
      end

      private def deliver(value : Exception | ::Process::Status, tid : TransactionId)
        return if @cancel_flag.get
        @result.set(value)
        @ready.set(true)
        tid.try_commit_and_resume
      end

      private def fetch_result : ::Process::Status
        case val = @result.get
        when Exception
          raise val
        else
          val
        end
      end
    end

    # Event that executes a system command and completes with its exit status.
    def self.system_evt(command : String) : Event(::Process::Status)
      CML.with_nack do |nack|
        SystemCommandEvent.new(command, nack)
      end
    end

    # Run a system command synchronously using an event under the hood.
    def self.system(command : String) : ::Process::Status
      CML.sync(system_evt(command))
    end
  end
end
