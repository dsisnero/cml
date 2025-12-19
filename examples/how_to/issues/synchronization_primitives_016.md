# synchronization_primitives_016.cr - Compilation Issue

## Source File
`/Users/dominic/repos/github.com/dsisnero/cml/examples/how_to/failing/synchronization_primitives_016.cr`

## Error
```text
Showing last frame. Use --error-trace for full trace.

In examples/how_to/synchronization_primitives_016.cr:11:35

 11 | barrier = CML::Barrier(Int32).new(->(x : Int32, y : Int32) { x + y }, 0)
                                        ^
Error: expected argument #1 to 'CML::Barrier(Int32).new' to be Proc(Int32, Int32), not Proc(Int32, Int32, Int32)

Overloads are:
 - CML::Barrier(T).new(update_fn : Proc(T, T), state : T)
 - CML::Barrier(T).new(initial_state : T, &block : (T -> T))

```

## Example Content
```crystal
# synchronization_primitives_016.cr
# Extracted from: how_to.md
# Section: synchronization_primitives
# Lines: 309-328
#
# ----------------------------------------------------------

require "../../src/cml"

# Create barrier with combining function
barrier = CML::Barrier(Int32).new(->(x : Int32, y : Int32) { x + y }, 0)

# Spawn multiple threads that synchronize at barrier
5.times do |i|
  CML.spawn do
    enrollment = barrier.enroll
    puts "Thread #{i} waiting at barrier"

    # Each thread contributes its index
    result = enrollment.wait(i)
    puts "Thread #{i} passed barrier with total: #{result}"

    enrollment.resign
  end
end

sleep 0.2
```

## Analysis Needed
1. Identify the root cause of the compilation error
2. Determine if it's a:
   - Syntax issue in the example
   - Missing dependency or require
   - Type system limitation
   - API change needed
3. Propose a fix
