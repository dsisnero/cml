require "./directory_walker"

root = ARGV[0]? || "."
workers = (ENV["WORKERS"]? || System.cpu_count).to_i
iterations = (ENV["ITERATIONS"]? || "3").to_i

handler = Proc(String, Int64).new do |path|
  begin
    info = File.info?(path)
    info ? info.size : 0_i64
  rescue ex : File::Error
    0_i64
  end
end

def run_case(name : String, iterations : Int32, &block : -> Array(Int64))
  times = [] of Time::Span
  last_sum = 0_i64

  iterations.times do
    result = nil
    start = Time.instant
    result = block.call
    times << (Time.instant - start)
    last_sum = result.not_nil!.sum
  end

  avg = times.sum / times.size
  puts "#{name}: avg=#{avg.total_milliseconds.round(2)}ms sum=#{last_sum}"
end

puts "root=#{root} workers=#{workers} iterations=#{iterations}"

run_case("serial", iterations) do
  DirectoryWalker.walk_serial(root, handler)
end

run_case("channel_fibers", iterations) do
  DirectoryWalker.walk_channel_fibers(root, workers, handler)
end

run_case("channel_threads", iterations) do
  DirectoryWalker.walk_channel_threads(root, workers, handler)
end

run_case("cml", iterations) do
  DirectoryWalker.walk_cml(root, workers, handler)
end
