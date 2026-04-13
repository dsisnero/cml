require "json"
require "./directory_walker"

root = ARGV[0]? || "."
workers = (ENV["WORKERS"]? || System.cpu_count).to_i
only = ENV["ONLY"]?

def word_count(path : String) : Int32
  count = 0
  in_word = false

  File.open(path) do |io|
    buf = Bytes.new(32_768)
    while (n = io.read(buf)) > 0
      i = 0
      while i < n
        b = buf[i]
        is_space = b == 32 || b == 9 || b == 10 || b == 13 || b == 12 || b == 11
        if is_space
          in_word = false
        elsif !in_word
          count += 1
          in_word = true
        end
        i += 1
      end
    end
  end

  count
end

def build_hash(results : Array(NamedTuple(path: String, word_count: Int32)))
  out = Hash(String, NamedTuple(filetype: String, word_count: Int32)).new
  results.each do |entry|
    out[entry[:path]] = {filetype: "rb", word_count: entry[:word_count]}
  end
  out
end

def run_case(name : String, only : String?, &block : -> Array(NamedTuple(path: String, word_count: Int32)))
  return nil if only && only != name
  start = Time.instant
  results = block.call
  duration = Time.instant - start
  hash = build_hash(results)
  puts "#{name}: files=#{hash.size} ms=#{duration.total_milliseconds.round(2)}"
  hash
end

handler = Proc(String, NamedTuple(path: String, word_count: Int32)).new do |path|
  next({path: "", word_count: 0}) unless path.ends_with?(".rb")
  info = File.info?(path)
  next({path: "", word_count: 0}) unless info && info.file?
  perms = info.permissions
  readable = perms.owner_read? || perms.group_read? || perms.other_read?
  next({path: "", word_count: 0}) unless readable
  {path: path, word_count: word_count(path)}
end

puts "root=#{root} workers=#{workers}"

serial_hash = run_case("serial", only) do
  DirectoryWalker.walk_serial(root, handler).reject { |entry| entry[:path].empty? }
end

fiber_hash = run_case("channel_fibers", only) do
  DirectoryWalker.walk_channel_fibers(root, workers, handler).reject { |entry| entry[:path].empty? }
end

thread_hash = run_case("channel_threads", only) do
  DirectoryWalker.walk_channel_threads(root, workers, handler).reject { |entry| entry[:path].empty? }
end

cml_hash = run_case("cml", only) do
  DirectoryWalker.walk_cml(root, workers, handler).reject { |entry| entry[:path].empty? }
end

output = {
  "root"            => root,
  "serial"          => serial_hash,
  "channel_fibers"  => fiber_hash,
  "channel_threads" => thread_hash,
  "cml"             => cml_hash,
}

filename = if only
             "examples/directory_walker/rb_wordcounts_#{only}.json"
           else
             "examples/directory_walker/rb_wordcounts.json"
           end
File.write(filename, output.to_json)
puts "wrote #{filename}"
