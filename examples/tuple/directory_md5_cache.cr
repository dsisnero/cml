require "option_parser"
require "digest/md5"
require "../../src/cml"

module TupleMd5CacheDemo
  alias L = CML::Linda

  TAG_TASK     = L::Helpers.sval("task")
  TAG_CACHE    = L::Helpers.sval("cache")
  TAG_RESULT   = L::Helpers.sval("result")
  TAG_SHUTDOWN = L::Helpers.sval("shutdown")

  record RunStats,
    elapsed : Time::Span,
    total_jobs : Int32,
    cache_hits : Int32,
    unique_files : Int32,
    workers : Int32,
    iterations : Int32,
    hashes : Hash(String, String)

  private def self.task_tuple(path : String, stamp : String) : L::Tuple
    L::TupleRep(L::ValAtom).new(TAG_TASK, [L::Helpers.sval(path), L::Helpers.sval(stamp)])
  end

  private def self.cache_tuple(path : String, stamp : String, md5 : String) : L::Tuple
    L::TupleRep(L::ValAtom).new(TAG_CACHE, [L::Helpers.sval(path), L::Helpers.sval(stamp), L::Helpers.sval(md5)])
  end

  private def self.result_tuple(filename : String, path : String, md5 : String, cached : Bool) : L::Tuple
    L::TupleRep(L::ValAtom).new(
      TAG_RESULT,
      [L::Helpers.sval(filename), L::Helpers.sval(path), L::Helpers.sval(md5), L::Helpers.bval(cached)]
    )
  end

  private def self.shutdown_tuple : L::Tuple
    L::TupleRep(L::ValAtom).new(TAG_SHUTDOWN, [] of L::ValAtom)
  end

  private def self.task_template : L::Template
    L::TupleRep(L::PatAtom).new(TAG_TASK, [L::Helpers.sform, L::Helpers.sform])
  end

  private def self.shutdown_template : L::Template
    L::TupleRep(L::PatAtom).new(TAG_SHUTDOWN, [] of L::PatAtom)
  end

  private def self.cache_template(path : String, stamp : String) : L::Template
    L::TupleRep(L::PatAtom).new(TAG_CACHE, [L::Helpers.spat(path), L::Helpers.spat(stamp), L::Helpers.sform])
  end

  private def self.result_template : L::Template
    L::TupleRep(L::PatAtom).new(TAG_RESULT, [L::Helpers.sform, L::Helpers.sform, L::Helpers.sform, L::Helpers.bform])
  end

  private def self.collect_files(root : String) : Array(String)
    files = [] of String
    walk = uninitialized Proc(String, Nil)
    walk = ->(dir : String) do
      Dir.each_child(dir) do |name|
        path = File.join(dir, name)
        begin
          next if File.symlink?(path)
          if File.directory?(path)
            next if name == ".git" || name == ".crystal-cache" || name == "node_modules"
            walk.call(path)
          elsif File.file?(path)
            files << path
          end
        rescue File::Error
          # Ignore unreadable entries and symlink-loop errors.
        end
      end
    end
    walk.call(root)
    files
  end

  private def self.file_stamp(path : String) : String?
    info = File.info(path)
    "#{info.size}:#{info.modification_time.to_unix}"
  rescue File::Error
    nil
  end

  private def self.compute_md5(path : String, iterations : Int32) : String
    data = File.read(path)
    digest = ""
    iterations.times do
      digest = Digest::MD5.hexdigest(data)
    end
    digest
  end

  private def self.try_cache_read(space : L::TupleSpace, path : String, stamp : String) : String?
    evt = space.rd_evt(cache_template(path, stamp))
    found = CML.select(evt, CML.timeout(1.millisecond))
    return nil if found.nil?
    vals = found.as(Array(L::ValAtom))
    vals[0].value.as(String)
  end

  private def self.run_once(files : Array(String), workers : Int32, repeats : Int32, iterations : Int32, verbose : Bool) : RunStats
    space = L.join_tuple_space
    worker_done = Channel(Nil).new

    workers.times do |wid|
      spawn do
        loop do
          msg = CML.select(space.in_evt(task_template), space.in_evt(shutdown_template)).as(Array(L::ValAtom))
          break if msg.empty?

          path = msg[0].value.as(String)
          stamp = msg[1].value.as(String)
          filename = File.basename(path)

          cached_md5 = try_cache_read(space, path, stamp)
          if cached_md5
            space.out(result_tuple(filename, path, cached_md5, true))
            puts "worker=#{wid} cached path=#{path}" if verbose
          else
            begin
              md5 = compute_md5(path, iterations)
              space.out(cache_tuple(path, stamp, md5))
              space.out(result_tuple(filename, path, md5, false))
              puts "worker=#{wid} computed path=#{path}" if verbose
            rescue File::Error
              # File may disappear between traversal and hashing.
              space.out(result_tuple(filename, path, "unavailable", false))
            end
          end
        end
        worker_done.send(nil)
      end
    end

    start = Time.instant
    cache_hits = 0
    hashes = Hash(String, String).new
    total_jobs = 0
    repeats.times do
      files.each do |path|
        stamp = file_stamp(path)
        next unless stamp
        space.out(task_tuple(path, stamp))
        total_jobs += 1
      end
    end

    total_jobs.times do
      result = CML.sync(space.in_evt(result_template))
      path = result[1].value.as(String)
      md5 = result[2].value.as(String)
      cached = result[3].value.as(Bool)
      hashes[path] = md5
      cache_hits += 1 if cached
    end

    workers.times { space.out(shutdown_tuple) }
    workers.times { worker_done.receive }

    RunStats.new(
      elapsed: Time.instant - start,
      total_jobs: total_jobs,
      cache_hits: cache_hits,
      unique_files: files.size,
      workers: workers,
      iterations: iterations,
      hashes: hashes
    )
  end

  private def self.print_hash_report(serial : RunStats, parallel : RunStats)
    serial_ms = serial.elapsed.total_milliseconds.round(2)
    parallel_ms = parallel.elapsed.total_milliseconds.round(2)
    puts "results:"
    serial.hashes.keys.sort.each do |path|
      name = File.basename(path)
      serial_md5 = serial.hashes[path]? || "missing"
      parallel_md5 = parallel.hashes[path]? || "missing"
      status = serial_md5 == parallel_md5 ? "ok" : "mismatch"
      puts "name=#{name} md5=#{parallel_md5} serial_ms=#{serial_ms} parallel_ms=#{parallel_ms} status=#{status}"
    end
  end

  def self.run(dir : String, workers : Int32, repeats : Int32, iterations : Int32, verbose : Bool, compare : Bool)
    raise "workers must be >= 1" if workers < 1
    raise "repeats must be >= 1" if repeats < 1
    raise "iterations must be >= 1" if iterations < 1

    files = collect_files(dir)
    raise "no files found under #{dir}" if files.empty?

    puts "dir=#{dir} files=#{files.size} repeats=#{repeats} iterations=#{iterations} workers=#{workers}"

    if compare && workers > 1
      serial = run_once(files, 1, repeats, iterations, verbose)
      parallel = run_once(files, workers, repeats, iterations, verbose)
      speedup = serial.elapsed.total_milliseconds / parallel.elapsed.total_milliseconds

      puts "serial: workers=#{serial.workers} jobs=#{serial.total_jobs} cache_hits=#{serial.cache_hits} elapsed=#{serial.elapsed.total_milliseconds.round(2)}ms"
      puts "parallel: workers=#{parallel.workers} jobs=#{parallel.total_jobs} cache_hits=#{parallel.cache_hits} elapsed=#{parallel.elapsed.total_milliseconds.round(2)}ms"
      puts "speedup: x#{speedup.round(2)}"
      print_hash_report(serial, parallel)
    else
      stats = run_once(files, workers, repeats, iterations, verbose)
      puts "workers=#{stats.workers} jobs=#{stats.total_jobs} cache_hits=#{stats.cache_hits} elapsed=#{stats.elapsed.total_milliseconds.round(2)}ms"
      puts "results:"
      stats.hashes.keys.sort.each do |path|
        puts "name=#{File.basename(path)} md5=#{stats.hashes[path]}"
      end
    end
  end
end

workers = ENV["WORKERS"]?.try(&.to_i) || 4
repeats = ENV["REPEATS"]?.try(&.to_i) || 2
dir = ENV["DIR"]? || File.expand_path("../..", __DIR__)
iterations = ENV["ITERATIONS"]?.try(&.to_i) || 100
verbose = false
compare = ENV["COMPARE"]? != "0"

OptionParser.parse do |parser|
  parser.banner = "Usage: crystal run directory_md5_cache.cr -- [options]"
  parser.on("--dir PATH", "Directory to hash (default: repo root)") { |v| dir = v }
  parser.on("--workers N", "Worker count for parallel run (default: 4)") { |v| workers = v.to_i }
  parser.on("--repeats N", "Submit each file N times (cache demo, default: 2)") { |v| repeats = v.to_i }
  parser.on("--iterations N", "MD5 iterations per file on cache miss (default: 100)") { |v| iterations = v.to_i }
  parser.on("--compare", "Compare workers=1 and workers=N runs (default: true)") { compare = true }
  parser.on("--no-compare", "Run only workers=N benchmark") { compare = false }
  parser.on("--verbose", "Print worker activity") { verbose = true }
  parser.on("-h", "--help", "Show help") { puts parser; exit(0) }
end

TupleMd5CacheDemo.run(dir, workers, repeats, iterations, verbose, compare)
