# common_pitfalls_and_solutions_031.cr
# Extracted from: how_to.md
# Section: common_pitfalls_and_solutions
# Lines: 1244-1288
#
# ----------------------------------------------------------

require "../../src/cml"

# Example: Deadlock and solution
ch1 = CML::Chan(Symbol).new
ch2 = CML::Chan(Symbol).new

# WRONG: Can deadlock if both try to send first
CML.spawn do
  puts "Thread 1: attempting to send :a"
  CML.sync(ch1.send_evt(:a))
  puts "Thread 1: sent :a, now waiting to receive from ch2"
  CML.sync(ch2.recv_evt)
  puts "Thread 1: received from ch2"
end

CML.spawn do
  puts "Thread 2: attempting to send :b"
  CML.sync(ch2.send_evt(:b))
  puts "Thread 2: sent :b, now waiting to receive from ch1"
  CML.sync(ch1.recv_evt)
  puts "Thread 2: received from ch1"
end

# The above will deadlock because each thread is waiting for the other
# to receive before it can send.

# BETTER: Use choice to avoid deadlock
CML.spawn do
  puts "Thread 3: using choice to avoid deadlock"
  CML.sync(
    CML.choose([
      CML.wrap(ch1.send_evt(:a)) {
        puts "Thread 3: sent :a, now waiting for ch2"
        CML.sync(ch2.recv_evt)
      },
      CML.wrap(ch2.recv_evt) {
        puts "Thread 3: received from ch2, now sending :a"
        CML.sync(ch1.send_evt(:a))
      },
    ])
  )
  puts "Thread 3: completed without deadlock"
end

sleep 0.1 # Allow threads to run
