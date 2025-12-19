#!/usr/bin/env crystal
# Cross-platform benchmark runner for Crystal CML
# - Enumerates benchmarks/*.cr
# - Runs each with --release --no-debug and CRYSTAL_WORKERS=1
# - Writes output to perf/baseline-<timestamp>/<name>.txt and mirrors to stdout

require "file_utils"

class TeeIO < IO
  getter a : IO
  getter b : IO
  @closed = false

  def initialize(@a : IO, @b : IO)
  end

  def read(slice : Bytes) : Int32
    # Not used (we only write)
    0
  end

  def write(slice : Bytes) : Nil
    @a.write(slice)
    @b.write(slice)
  end

  def flush : Nil
    @a.flush
    @b.flush
  end

  def close : Nil
    return if @closed
    @closed = true
    @a.flush
    @b.flush
  end

  def closed? : Bool
    @closed
  end
end

# Timestamped output dir
now = Time.local
stamp = now.to_s("%Y%m%d-%H%M%S")
outdir = File.join("perf", "baseline-#{stamp}")
FileUtils.mkdir_p(outdir)

# Env: lower noise runs
env = {"CRYSTAL_WORKERS" => "1"}

# Flags
flags = ["run", "--release", "--no-debug"]

# Enumerate benchmarks
bench_files = Dir.glob("benchmarks/*.cr").sort
if bench_files.empty?
  STDERR.puts "No benchmarks found under benchmarks/."
  exit 1
end

puts "Benchmark run: #{stamp}"
puts "CRYSTAL_WORKERS=#{env["CRYSTAL_WORKERS"]}"
puts "Output dir: #{outdir}"
puts

bench_files.each do |file|
  name = File.basename(file, ".cr")
  outfile = File.join(outdir, "#{name}.txt")
  puts "Running #{file} -> #{outfile}"

  File.open(outfile, "w") do |f|
    tee = TeeIO.new(STDOUT, f)
    start = Time.monotonic
    status = Process.run(
      command: "crystal",
      args: flags + [file],
      env: env,
      output: tee,
      error: tee
    )
    dur = Time.monotonic - start
    tee.flush
    tee.write("\n-- elapsed: #{dur.total_milliseconds.round(3)} ms\n".to_slice)
    tee.flush

    unless status.success?
      code = status.exit_code || 1
      STDERR.puts "Benchmark failed: #{file} (exit #{code})"
      exit code
    end
  end
  puts "Saved: #{outfile}"
  puts "----------------------------------------"
end

# List outputs
puts
puts "Artifacts in #{outdir}:"
Dir.each_child(outdir) { |fn| puts "- #{fn}" }
