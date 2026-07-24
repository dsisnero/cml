# Crystal CML Documentation (SML/NJ Parity)

This directory contains documentation adapted from the SML/NJ CML library,
converted to markdown format and updated to reflect the Crystal CML
implementation.

## File Mapping

| SML/NJ ML-DOC File | Crystal Markdown File | Status | Notes |
|-------------------|----------------------|--------|-------|
| `cml.mldoc` | [cml.md](cml.md) | ✅ Complete | Core CML structure |
| `sync-var.mldoc` | [sync-var.md](sync-var.md) | ✅ Complete | Synchronization variables (IVar, MVar) |
| `mailbox.mldoc` | [mailbox.md](mailbox.md) | ✅ Complete | Mailbox structure |
| `barrier.mldoc` | [barrier.md](barrier.md) | ✅ Complete | Barrier synchronization |
| `multicast.mldoc` | [multicast.md](multicast.md) | ✅ Complete | Multicast channels |
| `core-cml.mldoc` | [core-cml.md](core-cml.md) | ✅ Complete | Core CML internals |
| `run-cml.mldoc` | [run-cml.md](run-cml.md) | ✅ Complete | Running CML programs |
| `basics.mldoc` | [basics.md](basics.md) | ✅ Complete | Basic CML concepts |
| `os.mldoc` | [os.md](os.md) | ✅ Complete | OS interface |
| `os-io.mldoc` | [os-io.md](os-io.md) | ✅ Complete | OS I/O operations |
| `os-process.mldoc` | [os-process.md](os-process.md) | ✅ Complete | Process operations |
| `refman.mldoc` | [refman.md](refman.md) | ✅ Complete | Reference manual |
| `cml-lib.mldoc` | [cml-lib.md](cml-lib.md) | ✅ Complete | CML library |
| `trace-cml.mldoc` | [trace-cml.md](trace-cml.md) | ✅ Complete | Tracing facilities |
| `porting.mldoc` | [porting.md](porting.md) | ✅ Complete | Porting guide |

## Conversion Guidelines

When converting SML/NJ ML-DOC to markdown:

1.  **Preserve structure**: Maintain the original document organization
2.  **Update types**: Convert SML type signatures to Crystal equivalents
    *   `'a chan` → `Chan(T)`
    *   `'a event` → `Event(T)`
    *   `thread_id` → `Thread::Id`
    *   `unit` → `Nil`
    *   `'a -> 'b` → `A -> B`
    *   `'a option` → `T?`
3.  **Update function names**: Use Crystal naming conventions
    *   `sameChannel` → `same_channel`
    *   `iGetEvt` → `i_get_evt`
    *   `wrapHandler` → `wrap_handler`
4.  **Add Crystal-specific notes**: Document namespace differences, additional
   functions
5.  **Include prototypes**: Show usage examples with Crystal syntax
6.  **Cross-reference**: Link to other converted documents

## Crystal Namespace Differences

In Crystal, CML functionality is organized differently than in SML/NJ:

| SML/NJ Structure | Crystal Location |
|-----------------|------------------|
| `CML` | `CML` module |
| `SyncVar` | `CML::IVar(T)`, `CML::MVar(T)` classes, `CML.ivar`, `CML.mvar` functions |
| `Mailbox` | `CML::Mailbox(T)` class, `CML.mailbox` function |
| `Barrier` | `CML::Barrier` class, `CML.barrier` function |
| `Multicast` | `CML::Multicast` module, `CML.mchannel` function |
| Thread utilities | `CML::Thread` module, `CML.spawn`, `CML.get_tid`, etc. |
| IO operations | `CML::IOEvents` module, `CML.read_evt`, `CML.write_evt` |
| Socket operations | `CML::Socket` module, `CML.Socket.accept_evt`, etc. |

## Additional Crystal Features

The Crystal CML implementation includes several extensions not present in
SML/NJ:

*   `CML.after(duration, &block)` - Timeout with block execution
*   `CML.sleep(duration)` - Convenience sleep function
*   `CML.spawn_evt(&block)` - Event that spawns a thread and yields its thread id
*   `CML.nack(evt, &block)` - Add nack handler to existing event
*   Macro-based `choose` with varargs support
*   Tracing system with conditional compilation (`-Dtrace`)

## Contributing

To convert additional ML-DOC files:

1.  Examine the source `.mldoc` file in `smlnj/libraries/cml/doc/ML-Doc/`
2.  Create corresponding `.md` file in this directory
3.  Follow the conversion patterns established in `cml.md` and `sync-var.md`
4.  Update this README to mark the file as complete
5.  Ensure cross-references link correctly

## See Also

*   [Crystal CML Manual](../cml_manual.md) - High-level overview of Crystal CML
*   [SML/NJ CML Documentation](https://www.smlnj.org/doc/) - Original
  documentation
*   [Crystal CML Source Code](../../src/cml/) - Implementation source

---

*Last updated: 2026-02-05*
