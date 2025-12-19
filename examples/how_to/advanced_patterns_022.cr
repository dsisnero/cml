# advanced_patterns_022.cr
# Extracted from: how_to.md
# Section: advanced_patterns
# Lines: 875-916
#
# ----------------------------------------------------------

require "../../src/cml"

def make_event(evt : CML::Event(String), ack_msg : String, nack_msg : String) : CML::Event(String)
  CML.with_nack do |nack|
    # Spawn a thread that prints nack_msg if nack fires
    CML.spawn do
      CML.sync(nack)
      puts nack_msg
    end

    # Transform the original event to print ack_msg
    CML.wrap(evt) do |result|
      puts ack_msg
      result
    end
  end
end

# Example usage
ch1 = CML::Chan(String).new
ch2 = CML::Chan(String).new

# Spawn sender on ch2 (faster)
CML.spawn do
  sleep 0.01
  CML.sync(ch2.send_evt("from ch2"))
end

# Spawn sender on ch1 (slower)
CML.spawn do
  sleep 0.1
  CML.sync(ch1.send_evt("from ch1"))
end

# Create events with nack handlers
evt1 = make_event(ch1.recv_evt, "ch1 succeeded", "ch1 nacked")
evt2 = make_event(ch2.recv_evt, "ch2 succeeded", "ch2 nacked")

# Only one will succeed, the other will be nacked
result = CML.sync(CML.choose([evt1, evt2]))
puts "Result: #{result}"
# Output will show "ch2 succeeded" and "ch1 nacked"
