# Parallel Build System Example

This example demonstrates a parallel build system implemented using CML,
based on Chapter 7 of "Concurrent Programming in ML" by John H. Reppy.

## Overview

The build system translates a makefile into a **dataflow network** where:

- **Nodes** represent objects (files) to be built
- **Edges** represent dependencies (using multicast channels)
- **Messages** carry timestamps or errors between nodes

The system exploits natural parallelism in the dependency graph - independent
targets can be built concurrently using separate fibers.

## Architecture

```
                    ┌──────────────┐
                    │  Controller  │
                    └──────┬───────┘
                           │ signal
              ┌────────────┼────────────┐
              │            │            │
              ▼            ▼            ▼
         ┌────────┐   ┌────────┐   ┌────────┐
         │ util.c │   │ util.h │   │ main.c │    (leaf nodes)
         └───┬────┘   └───┬────┘   └───┬────┘
             │            │            │
             │            ├────────────┤
             │            │            │
             ▼            ▼            ▼
         ┌────────┐   ┌────────┐
         │ util.o │   │ main.o │               (internal nodes)
         └───┬────┘   └───┬────┘
             │            │
             └─────┬──────┘
                   │
                   ▼
              ┌────────┐
              │  prog  │                        (root node)
              └────────┘
```

## Key CML Concepts Demonstrated

1. **Multicast Channels**: Used to broadcast timestamps from objects to their
   successors. This avoids artificial ordering and potential deadlock.

2. **Concurrent Fibers**: Each node in the dependency graph is a separate fiber
   that independently waits for its antecedents and executes its action.

3. **Event Synchronization**: The controller uses CML events to coordinate the
   build process - signaling leaves to start and waiting for the root result.

4. **Dataflow Pattern**: Information flows through the network following the
   natural dependency order.

## Running the Example

1. Set up demo source files:
   ```bash
   bash setup_demo.sh
   ```

2. Run the build system:
   ```bash
   crystal run build_system.cr -- example.makefile
   ```

## Makefile Format

The build system uses a simplified makefile format:

```makefile
target : dependency1 dependency2 ...
    action
```

Rules:
- Dependency line: `target : deps...`
- Action line: Must be indented with tab or spaces
- Comments: Lines starting with `#`
- First rule defines the root target

## Code Structure

- `Stamp`: Either a `Time` timestamp or `:error`
- `Rule`: Target, antecedents, and action
- `make_node`: Creates a fiber for internal nodes
- `make_leaf`: Creates a fiber for leaf nodes
- `make_graph`: Builds the dataflow network
- `parse_makefile`: Parses the makefile
- `make`: Main entry point, returns a build function

## Comparison to SML/CML

| SML/CML | Crystal CML |
|---------|-------------|
| `datatype stamp = STAMP of Time.time \| ERROR` | `alias Stamp = Time \| :error` |
| `Multicast.mChannel()` | `CML::Multicast::MChan(T).new` |
| `Multicast.multicast(ch, msg)` | `ch.multicast(msg)` |
| `Multicast.recv port` | `CML.sync(port.recv_evt)` |
| `spawn f` | `spawn { f.call }` |
| `send(ch, v); recv ch` | `CML.sync(ch.send_evt(v)); CML.sync(ch.recv_evt)` |

## Extensions

Possible extensions mentioned in the book:
- Multiple root targets
- Demand-driven rebuilding (pull instead of push)
- Tools that produce multiple outputs
- Event-driven automatic rebuilding when files change
