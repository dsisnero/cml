require "../../src/cml"

module DirectoryWalker
  private class ThreadQueue(T)
    @queue = Deque(T).new
    @mtx : ::Thread::Mutex = ::Thread::Mutex.new
    @cv : ::Thread::ConditionVariable = ::Thread::ConditionVariable.new

    def push(value : T) : Nil
      @mtx.synchronize do
        @queue << value
        @cv.signal
      end
    end

    def pop : T
      @mtx.synchronize do
        while @queue.empty?
          @cv.wait(@mtx)
        end
        @queue.shift
      end
    end
  end

  private def self.collect_files(root : String) : Array(String)
    files = [] of String
    stack = [root]

    until stack.empty?
      path = stack.pop
      begin
        info = File.info?(path, follow_symlinks: false)
        next unless info
        if info.directory?
          Dir.each_child(path) do |entry|
            stack << File.join(path, entry)
          end
        elsif info.file?
          files << path
        end
      rescue ex : File::Error
      end
    end

    files
  end

  def self.walk_serial(root : String, handler : Proc(String, T)) : Array(T) forall T
    results = [] of T
    stack = [root]

    until stack.empty?
      path = stack.pop
      begin
        info = File.info?(path, follow_symlinks: false)
        next unless info
        if info.directory?
          Dir.each_child(path) do |entry|
            stack << File.join(path, entry)
          end
        elsif info.file?
          results << handler.call(path)
        end
      rescue ex : File::Error
        # Skip unreadable paths.
      end
    end

    results
  end

  def self.walk_serial(root : String, &block : String -> T) : Array(T) forall T
    walk_serial(root, Proc(String, T).new { |path| yield path })
  end

  def self.walk_channel_fibers(root : String, workers : Int32, handler : Proc(String, T)) : Array(T) forall T
    work_chan = Channel(String).new(1024)
    result_chan = Channel(T).new(1024)

    active = Atomic(Int32).new(workers)

    files = collect_files(root)
    spawn do
      files.each { |path| work_chan.send(path) }
      work_chan.close
    end

    workers.times do
      spawn do
        begin
          loop do
            path = work_chan.receive?
            break if path.nil?
            result_chan.send(handler.call(path))
          end
        ensure
          if active.add(-1) == 1
            result_chan.close
          end
        end
      end
    end

    results = [] of T
    loop do
      item = result_chan.receive?
      break if item.nil?
      results << item
    end
    results
  end

  def self.walk_channel_fibers(root : String, workers : Int32, &block : String -> T) : Array(T) forall T
    walk_channel_fibers(root, workers, Proc(String, T).new { |path| yield path })
  end

  def self.walk_channel_threads(root : String, workers : Int32, handler : Proc(String, T)) : Array(T) forall T
    work_queue = ThreadQueue(String?).new
    result_queue = ThreadQueue({done: Bool, value: T?}).new

    files = collect_files(root)
    files.each { |path| work_queue.push(path) }
    workers.times { work_queue.push(nil) }

    threads = [] of Thread
    workers.times do
      threads << Thread.new do
        {% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 || (flag?(:preview_mt) && flag?(:execution_context)) %}
          Thread.current.execution_context = CML::ExecutionContext.new("dir-walker", 1)
        {% end %}
        begin
          loop do
            path = work_queue.pop
            break if path.nil?
            result_queue.push({done: false, value: handler.call(path)})
          end
        ensure
          result_queue.push({done: true, value: nil})
        end
      end
    end

    results = [] of T
    done_count = 0
    while done_count < workers
      msg = result_queue.pop
      if msg[:done]
        done_count += 1
      elsif value = msg[:value]
        results << value
      end
    end

    threads.each(&.join)
    results
  end

  def self.walk_channel_threads(root : String, workers : Int32, &block : String -> T) : Array(T) forall T
    walk_channel_threads(root, workers, Proc(String, T).new { |path| yield path })
  end

  def self.walk_cml(root : String, workers : Int32, handler : Proc(String, T)) : Array(T) forall T
    work_box = CML::Mailbox(String?).new
    result_box = CML::Mailbox({done: Bool, value: T?}).new

    files = collect_files(root)
    workers.times do
      CML.spawn do
        begin
          loop do
            path = work_box.recv
            break if path.nil?
            result_box.send({done: false, value: handler.call(path)})
          end
        ensure
          result_box.send({done: true, value: nil})
        end
      end
    end

    files.each { |path| work_box.send(path) }
    workers.times { work_box.send(nil) }

    results = [] of T
    done_count = 0
    while done_count < workers
      msg = result_box.recv
      if msg[:done]
        done_count += 1
      elsif value = msg[:value]
        results << value
      end
    end
    results
  end

  def self.walk_cml(root : String, workers : Int32, &block : String -> T) : Array(T) forall T
    walk_cml(root, workers, Proc(String, T).new { |path| yield path })
  end
end
