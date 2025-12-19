# common_pitfalls_and_solutions_031.cr - Compilation Issue

## Source File
`/Users/dominic/repos/github.com/dsisnero/cml/examples/how_to/failing/common_pitfalls_and_solutions_031.cr`

## Error
```text
Showing last frame. Use --error-trace for full trace.

In examples/how_to/common_pitfalls_and_solutions_031.cr:38:16

 38 | CML.choose([
                 ^
Error: expected argument #1 to 'CML.choose' to be Array(CML::Event(Symbol)), not Array(CML::WrapEvent(Nil, Symbol) | CML::WrapEvent(Symbol, Nil))

Overloads are:
 - CML.choose(events : Array(Event(T))) forall T
 - CML.choose(*events : Event(T)) forall T

```

## Example Content
```crystal
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
      }
    ])
  )
  puts "Thread 3: completed without deadlock"
end

sleep 0.1  # Allow threads to run
```

## Analysis Needed
1. Identify the root cause of the compilation error
2. Determine if it's a:
   - Syntax issue in the example
   - Missing dependency or require
   - Type system limitation
   - API change needed
3. Propose a fix
