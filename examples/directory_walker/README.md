# Directory Walker Benchmarks

This directory contains several directory-walking implementations and a small
benchmark harness.

## Implementations

*   `DirectoryWalker.walk_serial` — single-threaded stack walk
*   `DirectoryWalker.walk_channel_fibers` — Crystal `Channel` + fiber workers
*   `DirectoryWalker.walk_channel_threads` — thread workers with CML `Mailbox`
  queues
*   `DirectoryWalker.walk_cml` — CML `Chan` + CML threads

Each implementation accepts a `Proc(String, T)` (or block) and collects results
into an array.

## Benchmark

```bash
crystal run -Dpreview_mt -Dexecution_context examples/directory_walker/benchmark.cr -- /path/to/root
```

Optional environment variables:

*   `WORKERS` (default: CPU count)
*   `ITERATIONS` (default: 3)

Example:

```bash
WORKERS=8 ITERATIONS=5 crystal run -Dpreview_mt -Dexecution_context examples/directory_walker/benchmark.cr -- .
```
