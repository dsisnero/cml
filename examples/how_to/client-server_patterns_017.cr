# client-server_patterns_017.cr
# Extracted from: how_to.md
# Section: client-server_patterns
# Lines: 360-426
#
# ----------------------------------------------------------

require "../../src/cml"

# Cell server interface
class Cell(T)
  getter req_ch : CML::Chan(T | Symbol)
  getter reply_ch : CML::Chan(T)

  def initialize(initial_value : T)
    @req_ch = CML::Chan(T | Symbol).new
    @reply_ch = CML::Chan(T).new

    # Server thread - runs independently
    CML.spawn do
      loop(initial_value)
    end
  end

  private def loop(current_value : T)
    # Server blocks here, waiting for next request
    # This is the ONLY blocking point in the server
    request = CML.sync(@req_ch.recv_evt)

    case request
    when :get
      # Send current value back to client
      CML.sync(@reply_ch.send_evt(current_value))
      # Loop with unchanged value
      loop(current_value)
    when T
      # Update value and loop
      loop(request)
    end
  end

  def get : T
    # Send GET request (may block if server is busy)
    CML.sync(@req_ch.send_evt(:get))
    # Wait for reply (definitely blocks until server responds)
    CML.sync(@reply_ch.recv_evt)
  end

  def put(value : T)
    # Send PUT request and return immediately
    # Client doesn't wait for server to process it
    CML.sync(@req_ch.send_evt(value))
  end
end

# Usage example showing concurrent access
cell = Cell(Int32).new(0)

# Multiple concurrent readers and writers
5.times do |i|
  CML.spawn do
    if i % 2 == 0
      # Writer thread
      cell.put(i * 10)
      puts "Thread #{i}: wrote #{i * 10}"
    else
      # Reader thread
      value = cell.get
      puts "Thread #{i}: read #{value}"
    end
  end
end

sleep 0.2
