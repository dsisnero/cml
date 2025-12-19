# error_handling_026.cr
# Extracted from: how_to.md
# Section: error_handling
# Lines: 1086-1118
#
# ----------------------------------------------------------

require "../../src/cml"

def with_timeout(evt : CML::Event(T), timeout : Time::Span) : CML::Event(T | Symbol) forall T
  timeout_evt = CML.wrap(CML.timeout(timeout)) { :timeout.as(T | Symbol) }
  wrapped_evt = CML.wrap(evt) { |x| x.as(T | Symbol) }
  CML.choose([wrapped_evt, timeout_evt])
end

def resilient_operation
  operation = CML.guard do
    # Simulate an operation that might fail
    if rand < 0.3
      raise "Random failure"
    end
    CML.always("success")
  end

  with_timeout(operation, 1.second)
end

# Retry loop with timeout
result = nil
3.times do |attempt|
  begin
    result = CML.sync(resilient_operation)
    break if result != :timeout
  rescue ex
    puts "Attempt #{attempt + 1} failed: #{ex.message}"
  end
  sleep 0.1
end

puts "Final result: #{result}"
