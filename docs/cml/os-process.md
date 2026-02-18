# The OS.Process structure

This document is adapted from the SML/NJ CML documentation (`os-process.mldoc`)
for the Crystal CML implementation. The OS.Process structure provides
event-based process creation and management.

## Overview

In SML/NJ CML, `OS.Process` provides a `systemEvt` function that executes a
system command and returns an event that becomes enabled when the sub-process
terminates. This allows non-blocking execution of external commands.

Crystal CML provides similar functionality through the `CML::Process` module
(not nested under `OS` for simplicity).

## Namespace

| SML/NJ Structure | Crystal Location | Description |
|-----------------|------------------|-------------|
| `OS.Process` | `CML::Process` module | Process operations |
| `OS.Process.systemEvt` | `CML::Process.system_evt` | Event-based command execution |

## Functions

### `systemEvt`

**SML signature**: `val systemEvt : string -> status event`

**Crystal equivalent**:

```crystal
def self.system_evt(command : String) : Event(Process::Status)
```

**Description**:

Executes a system command as a sub-process and returns an event that becomes
enabled when the sub-process terminates. The event value is the exit status of
the command. Raises `OS.SysErr` if the command cannot be executed.

**Crystal implementation**:

```crystal
module CML::Process
  class SystemCommandEvent < Event(::Process::Status)
    # Internal implementation
  end

  def self.system_evt(command : String) : Event(::Process::Status)
    CML.with_nack do |nack|
      SystemCommandEvent.new(command, nack)
    end
  end
end
```

**Usage**:

```crystal
# Execute a command asynchronously
evt = CML::Process.system_evt("ls -la")
CML.spawn do
  status = CML.sync(evt)
  puts "Command exited with status: #{status.exit_status}"
end
```

### Synchronous Wrapper

Crystal also provides a synchronous version for convenience:

```crystal
def self.system(command : String) : Process::Status
  CML.sync(system_evt(command))
end
```

## Error Handling

SML/NJ raises `OS.SysErr` if the command cannot be executed. Crystal raises
`IO::Error` or `Errno` exceptions for execution failures.

```crystal
begin
  CML::Process.system_evt("nonexistent-command")
rescue ex : IO::Error
  # Command not found or permission denied
end
```

## Nack Support

The Crystal implementation includes nack (negative acknowledgment) support,
allowing the sub-process to be terminated if another branch of a `choose` wins:

```crystal
choice = CML.choose(
  CML::Process.system_evt("long_running_command"),
  CML.timeout(5.seconds).wrap { :timeout }
)

result = CML.sync(choice)
# If timeout wins, the long_running_command will be terminated
```

## Porting Notes

When porting SML/NJ code that uses `OS.Process.systemEvt`:

1.  **Namespace**: Use `CML::Process.system_evt` instead of
   `OS.Process.systemEvt`
2.  **Status type**: Returns `Process::Status` instead of SML's `status` type
3.  **Error handling**: Catch `IO::Error` instead of `OS.SysErr`
4.  **Shell interpretation**: Commands are executed via shell (same as SML/NJ)

**Example conversion**:

**SML/NJ**:

```sml
val evt = OS.Process.systemEvt "ls -l"
val status = CML.sync evt
```

**Crystal**:

```crystal
evt = CML::Process.system_evt("ls -l")
status = CML.sync(evt)
```

## Additional Crystal Features

Crystal's `CML::Process` module may be extended with additional functionality:

*   Process spawning with arguments array (avoiding shell)
*   Process I/O redirection events
*   Process signal handling events
*   Process group management

## See Also

*   [OS Documentation](os.md) - OS structure overview
*   [CML Documentation](cml.md) - Core CML functions
*   [Crystal CML Manual](../cml_manual.md) - High-level overview
*   [SML/NJ OS.Process Documentation](https://www.smlnj.org/doc/) - Original
  documentation

---

*Adapted from SML/NJ OS.Process documentation version 1.1 (2003-03-10)*
