# advanced_patterns_024.cr
# Extracted from: how_to.md
# Section: advanced_patterns
# Lines: 987-1051
#
# ----------------------------------------------------------

require "../../src/cml"

# Stream implementation using I-variables
# Since Crystal doesn't support recursive type aliases, we implement
# streams as objects that wrap I-variables directly.

class Stream(T)
  @ivar : CML::IVar({T, Stream(T)}?)

  def initialize
    @ivar = CML::IVar({T, Stream(T)}?).new
  end

  # Get the event for reading the next stream element
  def event : CML::Event({T, Stream(T)}?)
    @ivar.i_get_evt
  end

  # Extend the stream with a value, returning the next stream
  def extend(value : T) : Stream(T)
    next_stream = Stream(T).new
    @ivar.i_put({value, next_stream})
    next_stream
  end

  # Terminate the stream
  def terminate
    @ivar.i_put(nil)
  end
end

def from_to(start : Int32, finish : Int32) : Stream(Int32)
  stream = Stream(Int32).new

  CML.spawn do
    current = stream
    start.upto(finish) do |i|
      current = current.extend(i)
    end
    current.terminate
  end

  stream
end

def take_n(stream : Stream(Int32), n : Int32) : Array(Int32)
  result = [] of Int32
  current = stream

  n.times do
    pair = CML.sync(current.event)
    break if pair.nil?

    value, next_stream = pair
    result << value
    current = next_stream
  end

  result
end

# Usage
strm = from_to(1, 10)
values = take_n(strm, 5)
puts "First 5 values: #{values}" # => [1, 2, 3, 4, 5]
