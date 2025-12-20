# Crystal CML How-To Guide

This guide demonstrates how to use the Crystal CML port (`src/cml`) with practical examples adapted from "Concurrent Programming in ML" by John Reppy.

## Table of Contents

1. [Getting Started](#getting-started)
2. [Basic Channel Operations](#basic-channel-operations)
3. [Event Combinators](#event-combinators)
4. [Selective Communication](#selective-communication)
5. [Timeouts and Timing](#timeouts-and-timing)
6. [Synchronization Primitives](#synchronization-primitives)
7. [Client-Server Patterns](#client-server-patterns)
8. [Process Networks](#process-networks)
9. [Advanced Patterns](#advanced-patterns)
10. [Error Handling](#error-handling)
11. [Performance Tips](#performance-tips)

> **Note for AI Agents and Contributors**: Before working with CML, review [Common Gotchas and Type Mismatches](docs/cml_gotchas.md) for important guidance on type system issues, especially with `choose` combinator.

## Getting Started

First, require the CML module:

```crystal
require "./src/cml"
```

Basic CML usage pattern:

```crystal
# Spawn a thread
CML.spawn do
  puts "Hello from thread #{CML.get_tid}"
end

# Yield to other threads
CML.yield

# Wait a bit for threads to complete
sleep 0.1
```

## Basic Channel Operations

### Creating and Using Channels

```crystal
# Create a channel for integers
ch = CML::Chan(Int32).new

# Spawn sender thread
CML.spawn do
  puts "Sender: about to send 42"
  CML.sync(ch.send_evt(42))
  puts "Sender: sent 42"
end

# Spawn receiver thread
CML.spawn do
  puts "Receiver: waiting for message"
  value = CML.sync(ch.recv_evt)
  puts "Receiver: got #{value}"
end

sleep 0.1
```

### Non-blocking Operations

```crystal
ch = CML::Chan(String).new

# Try to send without blocking
if ch.send_poll("hello")
  puts "Send succeeded immediately"
else
  puts "Send would block"
end

# Try to receive without blocking
if value = ch.recv_poll
  puts "Got: #{value}"
else
  puts "No message available"
end
```

## Event Combinators

### Basic Combinators

```crystal
# Always succeeds with a value
always_evt = CML.always(42)
value = CML.sync(always_evt)  # => 42

# Never succeeds (blocks forever)
never_evt = CML.never
# CML.sync(never_evt)  # Would block forever

# Transform event result
ch = CML::Chan(Int32).new
CML.spawn { CML.sync(ch.send_evt(10)) }

transformed = CML.wrap(ch.recv_evt) { |x| x * 2 }
result = CML.sync(transformed)  # => 20
puts "Transformed result: #{result}"
```

### Guard Combinator

```crystal
# Lazy event creation
expensive_evt = CML.guard do
  puts "Computing expensive value..."
  CML.always(compute_expensive_value())
end

# The computation only happens when we sync
result = CML.sync(expensive_evt)
```

### Choice Combinator

```crystal
ch1 = CML::Chan(Int32).new
ch2 = CML::Chan(String).new

# Spawn senders
CML.spawn { CML.sync(ch1.send_evt(100)) }
CML.spawn { CML.sync(ch2.send_evt("done")) }

# Choose between receiving from either channel
choice = CML.choose([
  CML.wrap(ch1.recv_evt) { |x| "Number: #{x}" },
  CML.wrap(ch2.recv_evt) { |s| "String: #{s}" }
])

result = CML.sync(choice)
puts "Chose: #{result}"  # Could be either "Number: 100" or "String: done"
```

## Selective Communication

### Basic Selection

```crystal
ch1 = CML::Chan(Int32).new
ch2 = CML::Chan(Int32).new

# Spawn senders with delays
CML.spawn do
  sleep 0.05
  CML.sync(ch1.send_evt(1))
end

CML.spawn do
  sleep 0.01  # This sender is faster
  CML.sync(ch2.send_evt(2))
end

# Select will choose the first available event
result = CML.select([
  ch1.recv_evt,
  ch2.recv_evt
])

puts "Selected: #{result}"  # Likely 2 from ch2
```

### Selection with Transformation

```crystal
ch_a = CML::Chan(String).new
ch_b = CML::Chan(String).new

CML.spawn { CML.sync(ch_a.send_evt("apple")) }
CML.spawn { CML.sync(ch_b.send_evt("banana")) }

# Different transformations for different channels
selection = CML.choose([
  CML.wrap(ch_a.recv_evt) { |s| "A: #{s.upcase}" },
  CML.wrap(ch_b.recv_evt) { |s| "B: #{s.reverse}" }
])

result = CML.sync(selection)
puts "Result: #{result}"  # Could be "A: APPLE" or "B: ananab"
```

## Timeouts and Timing

### Basic Timeouts

```crystal
# Timeout after 1 second
timeout_evt = CML.timeout(1.second)

# sync on timeout returns nil when timeout fires
result = CML.sync(timeout_evt)
puts "Timeout occurred" if result.nil?
```

### Timeout with Choice

```crystal
ch = CML::Chan(String).new

# Spawn a slow sender
CML.spawn do
  sleep(2.seconds)
  CML.sync(ch.send_evt("slow message"))
end

# Race between channel receive and timeout
result = CML.sync(
  CML.choose([
    ch.recv_evt,
    CML.wrap(CML.timeout(1.second)) { "timeout" }
  ])
)

puts "Result: #{result}"  # Will be "timeout" since sender takes 2 seconds
```

### Absolute Time Events

```crystal
# Event that fires at specific time
target_time = Time.utc + 5.seconds
at_time_evt = CML.at_time(target_time)

CML.spawn do
  CML.sync(at_time_evt)
  puts "5 seconds have passed!"
end
```

## Synchronization Primitives

### IVar (Write-Once Variable)

```crystal
# Create an IVar
ivar = CML::IVar(String).new

# Spawn writer
CML.spawn do
  sleep 0.1
  ivar.i_put("Hello from IVar!")
end

# Spawn reader
CML.spawn do
  value = CML.sync(ivar.i_get_evt)
  puts "IVar value: #{value}"
end

sleep 0.2
```

### MVar (Mutable Variable)

```crystal
# Create MVar with initial value
mvar = CML::MVar(Int32).new(0)

# Spawn multiple updaters
3.times do |i|
  CML.spawn do
    # Take current value, put new value
    current = CML.sync(mvar.m_take_evt)
    new_value = current + 1
    mvar.m_put(new_value)  # Synchronous put (no event needed)
    puts "Thread #{i}: #{current} -> #{new_value}"
  end
end

sleep 0.2
final = CML.sync(mvar.m_get_evt)
puts "Final value: #{final}"  # Should be 3
```

### Mailbox (Asynchronous Communication)

```crystal
# Create mailbox
mbox = CML::Mailbox(String).new

# Spawn multiple senders (non-blocking)
5.times do |i|
  CML.spawn do
    mbox.send("Message #{i}")
    puts "Sent message #{i}"
  end
end

# Spawn receiver
CML.spawn do
  5.times do
    msg = CML.sync(mbox.recv_evt)
    puts "Received: #{msg}"
  end
end

sleep 0.1
```

### Barrier Synchronization

```crystal
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

## Client-Server Patterns

### Simple Cell Server (From Book Section 3.2.3)

The cell server is a classic example that demonstrates several key CML concepts:

1. **Separation of interface and implementation** - Clients interact through simple `get` and `put` methods
2. **Serialized access** - The server thread ensures only one operation happens at a time
3. **Non-blocking design** - The server never blocks on individual operations
4. **Message passing** - All communication happens through channels

#### Design Rationale

**Why use two channels?**

- `req_ch`: For sending requests to the server (GET or PUT)
- `reply_ch`: For the server to send responses back (only for GET operations)

This separation allows the server to handle multiple clients without getting their responses mixed up. Each GET request gets its own reply on the shared reply channel, but since the server processes requests sequentially, there's no confusion.

**Why the server loop pattern?**
The server maintains state (`current_value`) and processes requests one at a time. This ensures:

- Atomic updates (no race conditions between concurrent puts)
- Consistent reads (a get always sees the most recent put)
- Simple error handling (exceptions don't corrupt server state)

**Why is this non-blocking?**

- The server only blocks on `CML.sync(@req_ch.recv_evt)` - waiting for the next request
- Clients block only when necessary (waiting for a reply on GET)
- PUT operations are asynchronous - clients don't wait for confirmation

```crystal
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
```

#### Key Insights

1. **The server is a state machine** - It transitions between states based on messages
2. **Channels provide synchronization** - The rendezvous ensures requests are processed in order
3. **No locks needed** - The single-threaded server naturally serializes access
4. **Scalable pattern** - This same pattern works for databases, caches, and other shared resources

This design is fundamental to CML: complex synchronization emerges from simple message-passing patterns, not from low-level locking primitives.

### Unique ID Service (From Book Section 4.2.1)

```crystal
class UniqueIdService
  @next_id : Int32 = 0
  @id_ch : CML::Chan(Int32)

  def initialize
    @id_ch = CML::Chan(Int32).new

    # Server thread
    CML.spawn do
      loop do
        CML.sync(@id_ch.send_evt(@next_id))
        @next_id += 1
      end
    end
  end

  def next_id : Int32
    CML.sync(@id_ch.recv_evt)
  end
end

# Usage
service = UniqueIdService.new

5.times do |i|
  CML.spawn do
    id = service.next_id
    puts "Thread #{i} got ID: #{id}"
  end
end

sleep 0.1
```

## Process Networks

### Sieve of Eratosthenes (From Book Section 3.2.4)

```crystal
def make_nat_stream(start : Int32 = 0) : CML::Chan(Int32)
  ch = CML::Chan(Int32).new

  CML.spawn do
    i = start
    loop do
      CML.sync(ch.send_evt(i))
      i += 1
    end
  end

  ch
end

def filter(p : Int32, in_ch : CML::Chan(Int32)) : CML::Chan(Int32)
  out_ch = CML::Chan(Int32).new

  CML.spawn do
    loop do
      i = CML.sync(in_ch.recv_evt)
      if i % p != 0
        CML.sync(out_ch.send_evt(i))
      end
    end
  end

  out_ch
end

def sieve : CML::Chan(Int32)
  primes_ch = CML::Chan(Int32).new

  CML.spawn do
    ch = make_nat_stream(2)

    loop do
      p = CML.sync(ch.recv_evt)
      CML.sync(primes_ch.send_evt(p))
      ch = filter(p, ch)
    end
  end

  primes_ch
end

# Get first 10 primes
primes_ch = sieve
10.times do |i|
  prime = CML.sync(primes_ch.recv_evt)
  puts "Prime #{i + 1}: #{prime}"
end
```

### Fibonacci Series Network (From Book Section 3.2.5)

```crystal
def add(in_ch1 : CML::Chan(Int32), in_ch2 : CML::Chan(Int32), out_ch : CML::Chan(Int32))
  CML.spawn do
    loop do
      # Receive from both channels (order doesn't matter with select)
      a, b = CML.sync(
        CML.choose([
          CML.wrap(in_ch1.recv_evt) { |a| {a, CML.sync(in_ch2.recv_evt)} },
          CML.wrap(in_ch2.recv_evt) { |b| {CML.sync(in_ch1.recv_evt), b} }
        ])
      )
      CML.sync(out_ch.send_evt(a + b))
    end
  end
end

def copy(in_ch : CML::Chan(Int32), out_ch1 : CML::Chan(Int32), out_ch2 : CML::Chan(Int32))
  CML.spawn do
    loop do
      x = CML.sync(in_ch.recv_evt)
      # Send to both outputs (order doesn't matter with select)
      CML.sync(
        CML.choose([
          CML.wrap(out_ch1.send_evt(x)) { out_ch2.send_evt(x) },
          CML.wrap(out_ch2.send_evt(x)) { out_ch1.send_evt(x) }
        ])
      )
    end
  end
end

def delay(initial : Int32?, in_ch : CML::Chan(Int32), out_ch : CML::Chan(Int32))
  CML.spawn do
    state = initial

    loop do
      case state
      when nil
        state = CML.sync(in_ch.recv_evt)
      else
        CML.sync(out_ch.send_evt(state))
        state = nil
      end
    end
  end
end

def make_fib_network : CML::Chan(Int32)
  out_ch = CML::Chan(Int32).new
  c1 = CML::Chan(Int32).new
  c2 = CML::Chan(Int32).new
  c3 = CML::Chan(Int32).new
  c4 = CML::Chan(Int32).new
  c5 = CML::Chan(Int32).new

  # Build the network
  delay(0, c4, c5)
  copy(c2, c3, c4)
  add(c3, c5, c1)
  copy(c1, c2, out_ch)

  # Seed with 1
  CML.spawn { CML.sync(c1.send_evt(1)) }

  out_ch
end

# Generate first 10 Fibonacci numbers
fib_ch = make_fib_network
10.times do |i|
  fib = CML.sync(fib_ch.recv_evt)
  puts "F(#{i + 1}): #{fib}"
end
```

### Parallel Build System (From Book Chapter 7)

The build system example demonstrates how CML can orchestrate complex workflows with dependencies. This is one of the most sophisticated examples in the book, showing how CML's event system can model real-world concurrent systems.

#### Key Concepts Demonstrated

1. **Dataflow Networks** - Build tasks as nodes in a dependency graph
2. **Multicast Channels** - Broadcasting completion signals to multiple dependents
3. **Non-blocking Coordination** - Tasks run in parallel where possible
4. **Error Propagation** - Failures cascade through the dependency graph
5. **Dynamic Graph Construction** - Building the task network from a makefile

#### Architecture Overview

```text
Controller
    │
    ▼ (multicast start signal)
Leaf Nodes (source files)
    │
    ▼ (completion timestamps)
Internal Nodes (build tasks)
    │
    ▼ (completion timestamps)
Root Node (final target)
    │
    ▼ (success/failure)
Controller
```

#### Why This Design Uses Specific CML Features

**1. Multicast Channels for Dependency Broadcasting**

- When a file finishes building, it needs to notify ALL its dependents
- Regular channels would require one channel per dependent (inefficient)
- Multicast channels allow one-to-many notification efficiently

**2. Two-Phase Execution**

- **Phase 1**: Signal all leaf nodes to check their timestamps
- **Phase 2**: Internal nodes wait for ALL antecedents before building
- This ensures correct dependency ordering without explicit scheduling

**3. Non-blocking Through Event Composition**

- Each node uses `CML.sync` only when it needs to wait
- While waiting, other nodes can make progress
- The system never deadlocks because dependencies form a DAG

**4. Error Handling Through Stamp Types**

- `Stamp = Time | StampError` - unified result type
- Errors propagate automatically through the graph
- No need for explicit error-checking at each node

```crystal
require "./src/cml"
require "./src/cml/multicast"

module BuildSystem
  # Stamp represents build result: either timestamp or error
  struct StampError; end
  ERROR = StampError.new
  alias Stamp = Time | StampError

  # Rule from makefile
  record Rule,
    target : String,
    antecedents : Array(String),
    action : String

  # Create an internal node (has dependencies)
  def self.make_node(target : String, antecedents : Array(CML::Multicast::Port(Stamp)), action : String) : CML::Multicast::Chan(Stamp)
    status = CML.mchannel(Stamp)

    CML.spawn do
      loop do
        # CRITICAL: Wait for ALL antecedents before proceeding
        # This is where parallelism happens - while this node waits,
        # other independent nodes can run
        stamps = antecedents.map { |port| CML.sync(port.recv_evt) }

        # Find most recent timestamp (or error)
        max_stamp = stamps.reduce(Time::UNIX_EPOCH.as(Stamp)) do |acc, stamp|
          case stamp
          when StampError then break ERROR.as(Stamp)
          when Time
            case acc
            when Time       then stamp > acc ? stamp : acc
            when StampError then ERROR
            else                 stamp
            end
          else
            acc
          end
        end

        case max_stamp
        when StampError
          # Error in dependency - propagate immediately
          status.multicast(ERROR)
        when Time
          # Check if rebuild is needed
          if obj_time = file_status(target)
            if obj_time < max_stamp
              # Dependency is newer - rebuild
              run_build_action(target, action, status)
            else
              # Up to date - just forward timestamp
              status.multicast(obj_time)
            end
          else
            # File doesn't exist - must build
            run_build_action(target, action, status)
          end
        end
      end
    end

    status
  end

  # Create a leaf node (no dependencies, just checks file)
  def self.make_leaf(signal_ch : CML::Multicast::Chan(Nil), target : String, action : String?)
    start = signal_ch.port
    status = CML.mchannel(Stamp)

    CML.spawn do
      loop do
        # Wait for controller's start signal
        # All leaves start simultaneously - MAXIMUM PARALLELISM
        CML.sync(start.recv_evt)

        if action
          # Leaf with action (e.g., "generate header.h")
          run_build_action(target, action, status)
        else
          # Source file - just check timestamp
          status.multicast(get_mtime(target))
        end
      end
    end

    status
  end

  def self.run_build_action(target : String, action : String, status : CML::Multicast::Chan(Stamp))
    if run_process(action)
      status.multicast(get_mtime(target))
    else
      STDERR.puts "Error making \"#{target}\""
      status.multicast(ERROR)
    end
  end

  # Main controller
  def self.make(file : String) : Proc(Bool)
    req_ch = CML.channel(Nil)      # Request channel (trigger build)
    repl_ch = CML.channel(Bool)    # Reply channel (success/failure)
    signal_ch = CML.mchannel(Nil)  # Multicast start signal

    # Parse makefile and build dependency graph
    content = File.read(file)
    parsed = parse_makefile(content)
    root_port = make_graph(signal_ch, parsed)

    # Controller thread
    CML.spawn do
      loop do
        # Wait for build request
        CML.sync(req_ch.recv_evt)

        # BROADCAST: Signal all leaves to start simultaneously
        # This is where the parallelism begins
        signal_ch.multicast(nil)

        # Wait for final result from root node
        result = CML.sync(root_port.recv_evt)

        # Send reply to caller
        case result
        when Time
          CML.sync(repl_ch.send_evt(true))
        else
          CML.sync(repl_ch.send_evt(false))
        end
      end
    end

    # Return build function
    -> : Bool {
      CML.sync(req_ch.send_evt(nil))
      CML.sync(repl_ch.recv_evt)
    }
  end
end

# Example makefile content
makefile_content = <<-MAKEFILE
program : main.o util.o
    gcc -o program main.o util.o

main.o : main.c util.h
    gcc -c main.c

util.o : util.c util.h
    gcc -c util.c

util.h : generate_header.sh
    sh generate_header.sh
MAKEFILE

# Usage
File.write("example.makefile", makefile_content)

begin
  build = BuildSystem.make("example.makefile")

  # Trigger build - this runs ALL possible tasks in parallel
  success = build.call

  if success
    puts "Build successful! All tasks completed with maximum parallelism."
  else
    puts "Build failed. Check error messages above."
  end
ensure
  File.delete("example.makefile") if File.exists?("example.makefile")
end
```

#### Why This Design is Non-blocking and Efficient

**1. Maximum Parallelism**

- All leaves start simultaneously when controller broadcasts
- Independent branches of the dependency graph run in parallel
- No task waits unless it actually has unmet dependencies

**2. No Central Scheduler**

- Each node manages its own dependencies using CML events
- The controller only coordinates start and collects final result
- This eliminates scheduler bottlenecks

**3. Efficient Resource Usage**

- Nodes only consume CPU when they have work to do
- Waiting nodes yield to other fibers (Crystal's cooperative multitasking)
- Memory usage scales with graph size, not with parallelism

**4. Natural Error Handling**

- Errors propagate through the graph automatically
- Failed nodes don't block unrelated branches
- The system degrades gracefully under partial failure

#### Comparison with Traditional Approaches

| Traditional Make | CML Build System |
|-----------------|------------------|
| Sequential dependency checking | Parallel dependency checking |
| Process-based parallelism | Fiber-based lightweight parallelism |
| File system polling | Event-driven notification |
| Complex scheduling logic | Simple dataflow semantics |
| Error stops entire build | Errors propagate but don't halt unrelated work |

This example shows how CML's event-based model can express complex coordination patterns naturally, without the complexity of traditional thread-based approaches.

## Advanced Patterns

### Negative Acknowledgements (with_nack)

```crystal
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
```

### Lock Server with Conditional Acceptance

```crystal
class LockServer
  enum Request
    Acquire
    Release
  end

  def initialize
    @req_ch = CML::Chan({Int32, Request, CML::Chan(Bool)?}).new
    @locks = Hash(Int32, Bool).new(false)

    CML.spawn { server_loop }
  end

  private def server_loop
    loop do
      lock_id, req_type, reply_ch = CML.sync(@req_ch.recv_evt)

      case req_type
      when Request::Acquire
        if !@locks[lock_id]?
          @locks[lock_id] = true
          reply_ch.try &.send(true)
        else
          reply_ch.try &.send(false)
        end

      when Request::Release
        @locks.delete(lock_id)
      end
    end
  end

  def acquire(lock_id : Int32) : Bool
    reply_ch = CML::Chan(Bool).new
    CML.sync(@req_ch.send_evt({lock_id, Request::Acquire, reply_ch}))
    CML.sync(reply_ch.recv_evt)
  end

  def release(lock_id : Int32)
    CML.sync(@req_ch.send_evt({lock_id, Request::Release, nil}))
  end
end

# Usage
server = LockServer.new

# Try to acquire same lock from multiple threads
lock_id = 1
5.times do |i|
  CML.spawn do
    if server.acquire(lock_id)
      puts "Thread #{i} acquired lock"
      sleep 0.05
      server.release(lock_id)
      puts "Thread #{i} released lock"
    else
      puts "Thread #{i} failed to acquire lock"
    end
  end
end

sleep 0.3
```

### Stream Processing with I-variables

```crystal
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
puts "First 5 values: #{values}"  # => [1, 2, 3, 4, 5]
```

## Error Handling

### Basic Error Handling in Events

```crystal
def safe_divide(a : Int32, b : Int32) : CML::Event(Float64)
  CML.guard do
    if b == 0
      CML.always(0.0)  # Default value on error
    else
      CML.always(a.to_f / b)
    end
  end
end

# Or with wrap_handler for exception handling
def safe_divide_with_handler(a : Int32, b : Int32) : CML::Event(Float64)
  CML.wrap_handler(CML.guard { CML.always(a.to_f / b) }) do |ex|
    puts "Division error: #{ex.message}"
    CML.always(0.0)
  end
end

# Usage
result = CML.sync(safe_divide(10, 2))
puts "10 / 2 = #{result}"  # => 5.0

result = CML.sync(safe_divide(10, 0))
puts "10 / 0 = #{result}"  # => 0.0
```

### Timeout with Error Recovery

```crystal
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
```

## Performance Tips

### 1. Use Non-blocking Operations When Possible

```crystal
# Example: Polling before blocking
ch = CML::Chan(Int32).new

# Spawn a sender that sends after a short delay
CML.spawn do
  sleep 0.01
  CML.sync(ch.send_evt(42))
end

# Instead of always blocking:
# value = CML.sync(ch.recv_evt)

# Consider polling first:
if value = ch.recv_poll
  puts "Got value immediately: #{value}"
else
  puts "No value available, falling back to blocking..."
  # Fall back to blocking
  value = CML.sync(ch.recv_evt)
  puts "Got value after blocking: #{value}"
end
```

### 2. Batch Operations with Choice

```crystal
# Example: Using choice for batch operations
ch1 = CML::Chan(Int32).new
ch2 = CML::Chan(String).new

# Spawn senders with different delays
CML.spawn do
  sleep 0.02  # Slower sender
  CML.sync(ch1.send_evt(100))
  puts "ch1 sent 100"
end

CML.spawn do
  sleep 0.01  # Faster sender
  CML.sync(ch2.send_evt("hello"))
  puts "ch2 sent 'hello'"
end

# Instead of sequential receives (which would wait for ch1 then ch2):
# value1 = CML.sync(ch1.recv_evt)
# value2 = CML.sync(ch2.recv_evt)

# Use choice to receive from whichever channel is ready first:
result = CML.sync(
  CML.choose([
    CML.wrap(ch1.recv_evt) { |v| {:ch1, v.as(Int32 | String)} },
    CML.wrap(ch2.recv_evt) { |v| {:ch2, v.as(Int32 | String)} }
  ])
)

puts "Received from #{result[0]} with value #{result[1]}"
sleep 0.03  # Wait for other send to complete
```

### 3. Use Guard for Expensive Computations

```crystal
# Defer expensive computation until needed
expensive_evt = CML.guard do
  puts "Computing..."
  result = expensive_computation()
  CML.always(result)
end

# Computation only happens here:
value = CML.sync(expensive_evt)
```

### 4. Limit Concurrency with Pools

```crystal
class WorkerPool(T, R)
  def initialize(@worker_count : Int32, &block : T -> R)
    @task_ch = CML::Chan({T, CML::Chan(R)}).new

    @worker_count.times do
      CML.spawn do
        loop do
          task, reply_ch = CML.sync(@task_ch.recv_evt)
          result = block.call(task)
          CML.sync(reply_ch.send_evt(result))
        end
      end
    end
  end

  def submit(task : T) : R
    reply_ch = CML::Chan(R).new
    CML.sync(@task_ch.send_evt({task, reply_ch}))
    CML.sync(reply_ch.recv_evt)
  end
end

# Usage
pool = WorkerPool(Int32, Int32).new(4) do |x|
  sleep 0.1  # Simulate work
  x * 2
end

# Submit multiple tasks
10.times do |i|
  CML.spawn do
    result = pool.submit(i)
    puts "Task #{i} -> #{result}"
  end
end

sleep 0.3
```

## Common Pitfalls and Solutions

### 1. Deadlock

```crystal
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

### 2. Resource Leaks

```crystal
# Always clean up resources
def with_resource
  resource = acquire_resource()

  begin
    yield resource
  ensure
    release_resource(resource)
  end
end

# Use in CML thread
CML.spawn do
  with_resource do |resource|
    # Use resource
  end
end
```

### 3. Unbounded Queue Growth

```crystal
# Use bounded channels or flow control
class BoundedChan(T)
  def initialize(@capacity : Int32)
    @chan = CML::Chan(T).new
    @semaphore = CML::MVar(Int32).new(@capacity)
  end

  def send(value : T)
    # Wait for space
    CML.sync(@semaphore.m_take_evt)
    CML.sync(@chan.send_evt(value))
  end

  def recv : T
    value = CML.sync(@chan.recv_evt)
    # Release space
    @semaphore.m_put(1)  # Synchronous put (no event needed)
    value
  end
end
```

## Understanding CML's Non-blocking Architecture

CML's power comes from its unique approach to concurrency. Unlike traditional thread-based systems, CML is built around **first-class events** and **non-blocking registration**.

### Why CML is Fundamentally Non-blocking

#### 1. Event Registration vs. Synchronization

```crystal
# Traditional approach (blocks during registration):
# thread1: ch.send(value)  # BLOCKS until someone receives
# thread2: ch.recv         # BLOCKS until someone sends

# CML approach (non-blocking registration):
evt = ch.send_evt(value)  # Just creates an event, doesn't block
# ... do other work ...
result = CML.sync(evt)    # Only blocks here, when we choose to synchronize
```

**Key Insight**: In CML, you describe what you *want* to do (create events), then decide when to actually do it (call `sync`). This separation allows for:

- Composing multiple possible actions before committing to one
- Trying operations without blocking
- Building complex synchronization from simple parts

#### 2. The Two-Phase Protocol

Every CML operation follows this pattern:

```crystal
# Phase 1: Non-blocking registration
def try_operation
  # Create event without blocking
  evt = some_operation_evt()

  # Try to complete immediately
  if can_complete_now?(evt)
    complete_immediately(evt)
  else
    # Phase 2: Block only if necessary
    register_for_completion(evt)
    # Fiber yields here, other work continues
  end
end
```

This is why the build system example works so well:

- Nodes register interest in their dependencies (non-blocking)
- While waiting, other independent nodes can run
- The system automatically finds maximum parallelism

#### 3. Choice and Commitment

The `choose` combinator is CML's secret weapon:

```crystal
# Describe multiple possible actions
choice = CML.choose([
  ch1.recv_evt,
  ch2.recv_evt,
  CML.timeout(1.second)
])

# Commit to exactly one
result = CML.sync(choice)
```

**Why this matters**:

- You can wait for the *first available* operation
- Timeouts become just another event to choose from
- The system never deadlocks waiting for the "wrong" channel

#### 4. Comparison with Other Models

| Model | Blocking Point | Concurrency Unit | Synchronization |
|-------|---------------|------------------|-----------------|
| **CML** | Only at `sync()` | Fibers/Events | First-class events |
| **Threads** | At every I/O call | OS Threads | Locks/Conditions |
| **Async/Await** | At `await` | Coroutines | Futures/Promises |
| **Actors** | On message receive | Actors | Message passing |

**CML's Advantage**: By making events first-class, CML allows you to:

1. Build synchronization abstractions (like the build system)
2. Compose concurrent operations declaratively
3. Reason about concurrency at a higher level

### Real-World Implications

#### The Build System Revisited

Let's examine why the build system is non-blocking:

```crystal
# Each node does this:
stamps = antecedents.map { |port| CML.sync(port.recv_evt) }
```

1. **Node A** tries to receive from its dependencies
2. If dependencies aren't ready, Node A's fiber yields
3. **Node B** (independent) can now run
4. When Node B finishes, it notifies its dependents
5. Node A resumes when ALL its antecedents are ready

**No central scheduler needed** - The event system automatically finds work that can proceed.

#### The Cell Server Revisited

The cell server demonstrates another non-blocking pattern:

```crystal
# Server loop
def loop(current_value)
  request = CML.sync(@req_ch.recv_evt)  # Only blocking point
  # Process request immediately
  case request
  when :get then send_reply(current_value)
  when T    then update_value(request)
  end
  loop(...)  # Tail recursion - constant stack usage
end
```

**Why this scales**:

- Server only blocks waiting for requests
- Processing is immediate (no I/O, no waiting)
- Many clients can be served by one server thread
- Memory usage is constant regardless of client count

### Key Design Principles

1. **Make Waiting Explicit**: Use `sync()` only when you actually need to wait
2. **Compose Before Committing**: Build complex event expressions before synchronizing
3. **Yield Freely**: Crystal fibers are cheap - yield often to allow parallelism
4. **Embrace Events**: Think in terms of "what events might happen" not "what threads should do"

This architecture is why CML can express complex coordination patterns (like the build system) simply and efficiently, while traditional approaches require complex scheduling logic.

## Conclusion

The Crystal CML port provides a powerful, composable concurrency model that follows the same principles as SML/NJ CML. Key takeaways:

1. **Events are first-class** - They can be passed as arguments, returned from functions, and composed
2. **sync() is the only blocking operation** - All event registration is non-blocking
3. **Combinators enable abstraction** - `wrap`, `guard`, `choose`, `with_nack` allow building complex synchronization from simple parts
4. **Channels provide rendezvous synchronization** - Synchronous communication with strong guarantees
5. **The model is deterministic** - With proper design, concurrent programs can be reasoned about formally

For more examples, see the `examples/` directory and the original book "Concurrent Programming in ML" by John Reppy.

## Linda Tuple Space System (From Book Chapter 9)

The Linda tuple space system is one of the most sophisticated examples in the book, demonstrating how CML can implement distributed coordination primitives. Linda provides a **distributed shared memory** model where processes communicate by reading and writing **tuples** (structured data) to a shared **tuple space**.

### Key Linda Concepts

1. **Tuple Space**: A globally shared, associative memory
2. **Tuples**: Structured data `(tag, field1, field2, ...)`
3. **Templates**: Patterns with wildcards and formals for matching
4. **Operations**:
   - `out(tuple)`: Put a tuple into the space
   - `in(template)`: Remove and return a matching tuple
   - `rd(template)`: Read (non-destructively) a matching tuple

### Why Linda is Interesting for CML

1. **Distributed Coordination**: Shows how CML can build distributed systems
2. **Complex Protocols**: Uses multiple CML features together
3. **Real-world Pattern**: Tuple spaces are used in real distributed systems

### Architecture Overview

The CML-Linda implementation uses a **read-all, write-one** distribution strategy:

```text
Client Program
    │
    ▼ (local channels)
Tuple-Server Proxies (one per server)
    │
    ▼ (network or local)
Tuple Servers (distributed)
    │
    ▼ (local storage)
Tuple Stores (hash tables)
```

### How CML Classes are Used

#### 1. **Channels for Local Communication**

```crystal
# Client ↔ Proxy communication
req_ch = CML::Chan(Request).new
reply_ch = CML::Chan(Array(ValAtom)).new

# Proxy ↔ Tuple Server communication
server_ch = CML::Chan(ServerMessage).new
```

#### 2. **Multicast Channels for Broadcasting**

```crystal
# Broadcasting input requests to all servers
req_mch = CML.mchannel(InputRequest)

# Each proxy gets a port
proxy_port = req_mch.port
```

#### 3. **with_nack for Transaction Management**

```crystal
def in_evt(template : Template) : CML::Event(Array(ValAtom))
  CML.with_nack do |nack|
    # Create transaction
    reply = CML.channel(Array(ValAtom))
    waiter_id = next_id()

    # Broadcast request to all servers
    CML.sync(@req_ch.send_evt(WaitRequest.new(template, reply, true, waiter_id)))

    # Cancel if nack fires
    CML.spawn do
      CML.sync(nack)
      CML.sync(@req_ch.send_evt(CancelRequest.new(waiter_id)))
    end

    reply.recv_evt
  end
end
```

#### 4. **Mailboxes for Asynchronous Network Communication**

```crystal
# Network buffer threads use mailboxes
net_mbox = CML::Mailbox(NetworkMessage).new

# Input buffer thread
CML.spawn do
  loop do
    msg = CML.sync(net_mbox.recv_evt)
    route_message(msg)
  end
end
```

### Complete Linda Implementation Example

Here's a simplified but complete implementation showing the key patterns:

```crystal
require "./src/cml"
require "./src/cml/multicast"

module CML
  module Linda
    # Value atoms (integers, strings, booleans)
    struct ValAtom
      enum Kind
        Int; String; Bool
      end

      getter kind : Kind
      getter value : Int32 | String | Bool

      def initialize(@kind, @value); end

      def self.int(i : Int32) = new(Kind::Int, i)
      def self.string(s : String) = new(Kind::String, s)
      def self.bool(b : Bool) = new(Kind::Bool, b)
    end

    # Pattern atoms (literals, formals, wildcards)
    struct PatAtom
      enum Kind
        IntLiteral; StringLiteral; BoolLiteral
        IntFormal; StringFormal; BoolFormal
        Wild
      end

      getter kind : Kind
      getter value : Int32 | String | Bool | Nil

      def initialize(@kind, @value = nil); end

      def self.int_literal(i : Int32) = new(Kind::IntLiteral, i)
      def self.string_literal(s : String) = new(Kind::StringLiteral, s)
      def self.bool_literal(b : Bool) = new(Kind::BoolLiteral, b)
      def self.int_formal = new(Kind::IntFormal)
      def self.string_formal = new(Kind::StringFormal)
      def self.bool_formal = new(Kind::BoolFormal)
      def self.wild = new(Kind::Wild)
    end

    # Tuple representation
    struct TupleRep(T)
      getter tag : ValAtom
      getter fields : Array(T)

      def initialize(@tag, @fields); end
    end

    alias Tuple = TupleRep(ValAtom)
    alias Template = TupleRep(PatAtom)

    # Server requests
    abstract struct Request
    end

    struct OutRequest < Request
      getter tuple : Tuple
      def initialize(@tuple); end
    end

    struct InRequest < Request
      getter template : Template
      getter reply : CML::Chan(Array(ValAtom))
      getter destructive : Bool
      getter id : Int64

      def initialize(@template, @reply, @destructive, @id); end
    end

    struct CancelRequest < Request
      getter id : Int64
      def initialize(@id); end
    end

    # Distributed Tuple Space
    class DistributedTupleSpace
      @req_mch : CML::Multicast::Chan(Request)  # Multicast to all proxies
      @output_ch : CML::Chan(Tuple)             # Output to distribution server
      @next_id = Atomic(Int64).new(0)

      def initialize(server_count : Int32)
        # Create multicast channel for broadcasting input requests
        @req_mch = CML.mchannel(Request)

        # Create output channel
        @output_ch = CML::Chan(Tuple).new

        # Create tuple servers and proxies
        create_servers_and_proxies(server_count)

        # Create output distribution server
        create_output_server(server_count)
      end

      private def create_servers_and_proxies(count : Int32)
        count.times do |server_id|
          # Each server has its own storage
          server = TupleServer.new(server_id)

          # Create proxy for this server
          proxy_port = @req_mch.port
          proxy = ServerProxy.new(server_id, server, proxy_port)

          # Start proxy thread
          CML.spawn { proxy.run }
        end
      end

      private def create_output_server(server_count : Int32)
        CML.spawn do
          servers = Array(TupleServer).new(server_count)
          current = 0

          loop do
            tuple = CML.sync(@output_ch.recv_evt)

            # Round-robin distribution (simplified policy)
            server = servers[current]
            server.out(tuple)

            current = (current + 1) % server_count
          end
        end
      end

      def out(tuple : Tuple)
        CML.sync(@output_ch.send_evt(tuple))
      end

      def in_evt(template : Template) : CML::Event(Array(ValAtom))
        CML.with_nack do |nack|
          reply = CML.channel(Array(ValAtom))
          waiter_id = @next_id.add(1)

          # Broadcast request to all proxies
          @req_mch.multicast(
            InRequest.new(template, reply, true, waiter_id)
          )

          # Cancel if operation is aborted
          CML.spawn do
            CML.sync(nack)
            @req_mch.multicast(CancelRequest.new(waiter_id))
          end

          reply.recv_evt
        end
      end

      def rd_evt(template : Template) : CML::Event(Array(ValAtom))
        CML.with_nack do |nack|
          reply = CML.channel(Array(ValAtom))
          waiter_id = @next_id.add(1)

          # Broadcast request (non-destructive)
          @req_mch.multicast(
            InRequest.new(template, reply, false, waiter_id)
          )

          # Cancel if aborted
          CML.spawn do
            CML.sync(nack)
            @req_mch.multicast(CancelRequest.new(waiter_id))
          end

          reply.recv_evt
        end
      end
    end

    # Tuple Server (manages local storage)
    class TupleServer
      @id : Int32
      @tuples = [] of Tuple
      @waiters = Hash(Int64, InRequest).new

      def initialize(@id); end

      def out(tuple : Tuple)
        # Check if any waiter matches
        matched_id = nil
        @waiters.each do |id, waiter|
          if matches?(waiter.template, tuple)
            matched_id = id
            # Send reply to waiter
            bindings = extract_bindings(waiter.template, tuple)
            CML.sync(waiter.reply.send_evt(bindings))

            # Remove tuple if destructive
            unless waiter.destructive
              @tuples << tuple
            end

            break
          end
        end

        if matched_id
          @waiters.delete(matched_id)
        else
          @tuples << tuple
        end
      end

      def in_request(req : InRequest)
        # Try to match with existing tuples
        matched_index = @tuples.index do |tuple|
          matches?(req.template, tuple)
        end

        if matched_index
          tuple = @tuples[matched_index]
          bindings = extract_bindings(req.template, tuple)

          # Remove if destructive
          @tuples.delete_at(matched_index) if req.destructive

          # Send reply
          CML.sync(req.reply.send_evt(bindings))
        else
          # Remember waiter
          @waiters[req.id] = req
        end
      end

      def cancel_request(id : Int64)
        @waiters.delete(id)
      end

      private def matches?(template : Template, tuple : Tuple) : Bool
        return false unless template.tag == tuple.tag
        return false unless template.fields.size == tuple.fields.size

        template.fields.each_with_index do |pat, i|
          val = tuple.fields[i]

          case pat.kind
          when PatAtom::Kind::IntLiteral
            return false unless val.kind == ValAtom::Kind::Int && val.value == pat.value
          when PatAtom::Kind::StringLiteral
            return false unless val.kind == ValAtom::Kind::String && val.value == pat.value
          when PatAtom::Kind::BoolLiteral
            return false unless val.kind == ValAtom::Kind::Bool && val.value == pat.value
          when PatAtom::Kind::IntFormal
            return false unless val.kind == ValAtom::Kind::Int
          when PatAtom::Kind::StringFormal
            return false unless val.kind == ValAtom::Kind::String
          when PatAtom::Kind::BoolFormal
            return false unless val.kind == ValAtom::Kind::Bool
          when PatAtom::Kind::Wild
            # Matches anything
          end
        end

        true
      end

      private def extract_bindings(template : Template, tuple : Tuple) : Array(ValAtom)
        bindings = [] of ValAtom

        template.fields.each_with_index do |pat, i|
          val = tuple.fields[i]

          case pat.kind
          when PatAtom::Kind::IntFormal,
               PatAtom::Kind::StringFormal,
               PatAtom::Kind::BoolFormal,
               PatAtom::Kind::Wild
            bindings << val
          else
            # Literals don't produce bindings
          end
        end

        bindings
      end
    end

    # Server Proxy (mediates between clients and servers)
    class ServerProxy
      @server_id : Int32
      @server : TupleServer
      @request_port : CML::Multicast::Port(Request)
      @request_ch : CML::Chan(Request)

      def initialize(@server_id, @server, request_port)
        @request_port = request_port
        @request_ch = CML::Chan(Request).new
      end

      def run
        # Forward multicast requests to server
        CML.spawn do
          loop do
            req = CML.sync(@request_port.recv_evt)
            handle_request(req)
          end
        end

        # Also handle direct requests (for output)
        loop do
          req = CML.sync(@request_ch.recv_evt)
          handle_request(req)
        end
      end

      private def handle_request(req : Request)
        case req
        when OutRequest
          @server.out(req.tuple)
        when InRequest
          @server.in_request(req)
        when CancelRequest
          @server.cancel_request(req.id)
        end
      end
    end
  end
end

# Example: Dining Philosophers with Linda
def dining_philosophers(n : Int32)
  space = CML::Linda::DistributedTupleSpace.new(1)  # Single server for demo

  # Helper functions for creating tuples
  def chopstick_tuple(pos : Int32)
    tag = CML::Linda::ValAtom.string("chopstick")
    fields = [CML::Linda::ValAtom.int(pos)]
    CML::Linda::TupleRep.new(tag, fields)
  end

  def ticket_tuple
    tag = CML::Linda::ValAtom.string("ticket")
    fields = [] of CML::Linda::ValAtom
    CML::Linda::TupleRep.new(tag, fields)
  end

  # Initialize tuple space with chopsticks and tickets
  n.times do |i|
    space.out(chopstick_tuple(i))
  end

  (n - 1).times do
    space.out(ticket_tuple)
  end

  # Philosopher thread
  philosopher = ->(id : Int32) {
    loop do
      puts "Philosopher #{id} thinking..."
      sleep rand(0.1..0.5)

      puts "Philosopher #{id} hungry..."

      # Need ticket and two chopsticks
      ticket_template = CML::Linda::Template.new(
        CML::Linda::ValAtom.string("ticket"),
        [] of CML::Linda::PatAtom
      )

      left_chop = CML::Linda::Template.new(
        CML::Linda::ValAtom.string("chopstick"),
        [CML::Linda::PatAtom.int_literal(id)]
      )

      right_chop = CML::Linda::Template.new(
        CML::Linda::ValAtom.string("chopstick"),
        [CML::Linda::PatAtom.int_literal((id + 1) % n)]
      )

      # Get ticket (blocks until available)
      CML.sync(space.in_evt(ticket_template))

      # Get chopsticks
      CML.sync(space.in_evt(left_chop))
      CML.sync(space.in_evt(right_chop))

      puts "Philosopher #{id} eating..."
      sleep rand(0.1..0.3)

      # Return resources
      space.out(chopstick_tuple(id))
      space.out(chopstick_tuple((id + 1) % n))
      space.out(ticket_tuple)

      puts "Philosopher #{id} finished eating"
    end
  }

  # Start philosophers
  n.times do |i|
    CML.spawn { philosopher.call(i) }
  end

  # Run for a while
  sleep 5.0
  puts "Dinner is over!"
end

# Run the example
dining_philosophers(5)
```

### Key Design Insights

#### 1. **Why Multicast Channels?**

- Input requests must be broadcast to **all** tuple servers
- Regular channels would require N channels for N servers
- Multicast provides efficient one-to-many communication
- Each proxy gets a `port` from the multicast channel

#### 2. **Why with_nack for Input Operations?**

- Input operations can be used in `choose` expressions
- If another event is chosen, the input must be cancelled
- `with_nack` provides automatic cancellation
- Cancellation messages must be sent to all servers

#### 3. **Why Separate Output Server?**

- Output distribution is a policy decision
- Round-robin, hashing, or locality-aware policies
- Separating policy from mechanism follows good design
- Output server can be replaced without affecting clients

#### 4. **Why Proxies?**

- Provide uniform interface to local and remote servers
- Hide network communication details
- Manage transaction state (mapping local IDs to remote IDs)
- Buffer messages if server is busy

#### 5. **How This Achieves Distribution:**

- **Read-all**: Input operations query all servers
- **Write-one**: Output operations send to one server (by policy)
- **Fault tolerance**: Can be added with replication
- **Scalability**: More servers = more capacity

### Comparison with Simplified Implementation

The existing `src/cml/linda.cr` is a **local-only** simplification. The full distributed implementation adds:

1. **Network layer** with socket I/O events
2. **Message serialization** for network communication
3. **Transaction management** with unique IDs
4. **Failure handling** (not shown in simplified version)
5. **Join protocol** for dynamic membership

### Why This Matters for CML Understanding

The Linda implementation demonstrates how CML can be used to build **complex distributed systems** from simple primitives:

1. **Channels** → Local communication
2. **Multicast** → Broadcast communication
3. **with_nack** → Transaction management
4. **Events** → Non-blocking operations
5. **Threads** → Concurrent components

This shows that CML isn't just for simple concurrency - it's a **systems programming language** capable of building sophisticated distributed coordination primitives.

## Practical Summary: What We've Learned

Through these examples, we've seen how CML provides a unified model for concurrent programming:

### 1. **From Simple to Complex**

- **Cell Server**: Basic client-server pattern with serialized access
- **Build System**: Complex workflow coordination with dependencies
- **Linda**: Distributed coordination with sophisticated protocols

### 2. **Key CML Patterns in Practice**

| Pattern | Example | CML Features Used |
|---------|---------|-------------------|
| **Client-Server** | Cell Server | Channels, `sync()`, server loop |
| **Dataflow** | Build System | Multicast, event composition |
| **Distributed Coordination** | Linda | `with_nack`, multicast, transaction management |
| **Non-blocking Design** | All examples | Event-based registration, `choose()` |

### 3. **Why CML's Design Matters**

1. **Composability**: Events can be combined before synchronization
2. **Abstraction**: Complex patterns emerge from simple primitives
3. **Correctness**: The model prevents common concurrency bugs
4. **Performance**: Non-blocking design enables maximum parallelism

### 4. **Applying These Patterns**

When building with CML:

1. **Think in events**, not threads
2. **Compose before committing** with `choose()` and `wrap()`
3. **Use `with_nack`** for transactional operations
4. **Broadcast with multicast** for one-to-many communication
5. **Keep servers simple** with single-threaded event loops

The examples from the book show that CML isn't just an academic exercise - it's a practical tool for building real concurrent systems, from simple synchronization primitives to complex distributed coordination.

## Further Reading

1. `src/cml.cr` - Core CML implementation
2. `src/cml/` - Primitive implementations (ivar, mvar, mailbox, etc.)
3. `examples/` - Working examples of CML patterns
4. `spec/` - Test specifications showing correct usage
5. Original book: "Concurrent Programming in ML" by John Reppy
6. Chapter 9 - Complete Linda implementation details