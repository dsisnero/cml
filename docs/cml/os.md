# The OS structure

This document is adapted from the SML/NJ CML documentation (`os.mldoc`) for the Crystal CML implementation. The OS structure provides operating system interfaces for file systems, directories, processes, and I/O subsystems.

## Overview

In SML/NJ CML, the `OS` structure is a container for substructures that interact with the operating system:

* **OS** - Top-level container (maps to `CML::OS` module in Crystal)
* **OS.Process** - Process creation and management (`CML::OS::Process`)
* **OS.IO** - I/O event operations (`CML::OS::IO`)

Crystal's CML implementation provides similar functionality through dedicated modules, though the exact API differs from SML/NJ.

## Namespace

In Crystal, OS-related functionality is distributed across several modules:

| SML/NJ Structure | Crystal Location | Description |
|-----------------|------------------|-------------|
| `OS` | `CML::OS` module (placeholder) | Container for OS subsystems |
| `OS.Process` | `CML::OS::Process` module | Process operations |
| `OS.IO` | `CML::OS::IO` module | I/O event operations |
| `OS.FileSys` | `CML::IOEvents` module | File system operations |
| `OS.Path` | Crystal's `File` and `Path` classes | Path manipulation |

## OS Container Structure

The `OS` structure itself contains no functions in SML/NJ; it serves only as a namespace for substructures. In Crystal, the `CML::OS` module is similarly a namespace container.

```crystal
module CML::OS
  # Container module for OS-related functionality
end
```

## OS.Process Substructure

Process operations allow creating and managing child processes. In SML/NJ, this includes functions like `execute`, `system`, `exit`, etc.

Crystal provides process operations through the `CML::OS::Process` module (or directly via Crystal's `Process` class for non-event operations).

```crystal
module CML::OS::Process
  # Execute a command as a child process
  def self.execute(cmd : String, args : Array(String) = [] of String) : Event(Process::Status)

  # Wait for a process to terminate
  def self.wait_pid(pid : Int32) : Event(Process::Status)

  # Terminate the current process
  def self.exit(status : Int32) : NoReturn
end
```

## OS.IO Substructure

I/O operations provide event-based versions of file and stream operations. In SML/NJ, this includes functions like `openIn`, `openOut`, `close`, etc.

Crystal provides I/O events through the `CML::IOEvents` module (which is not under `CML::OS` for historical reasons).

```crystal
module CML::IOEvents
  # Open a file for reading
  def self.open_read(path : String) : Event(IO::FileDescriptor)

  # Open a file for writing
  def self.open_write(path : String) : Event(IO::FileDescriptor)

  # Read from a file descriptor
  def self.read(fd : IO::FileDescriptor, bytes : Int32) : Event(String)

  # Write to a file descriptor
  def self.write(fd : IO::FileDescriptor, data : String) : Event(Int32)

  # Close a file descriptor
  def self.close(fd : IO::FileDescriptor) : Event(Nil)
end
```

## File System Operations

SML/NJ's `OS.FileSys` structure provides file system operations. In Crystal, these are available through `CML::IOEvents` and Crystal's standard `File` and `Dir` classes.

```crystal
# Check if file exists (non-blocking)
CML::IOEvents.file_exists?(path : String) : Event(Bool)

# Get file status
CML::IOEvents.stat(path : String) : Event(File::Info)

# List directory contents
CML::IOEvents.read_dir(path : String) : Event(Array(String))
```

## Path Operations

SML/NJ's `OS.Path` structure provides path manipulation functions. Crystal provides similar functionality through `File` and `Path` classes.

```crystal
# Join path components
File.join("dir", "file.txt")  # => "dir/file.txt"

# Get directory name
File.dirname("/path/to/file") # => "/path/to"

# Get base name
File.basename("/path/to/file.txt") # => "file.txt"
```

## Porting Notes

When porting SML/NJ CML code that uses the `OS` structure:

1.  **Process operations**: Use `CML::OS::Process` or Crystal's `Process` class
2.  **I/O operations**: Use `CML::IOEvents` module
3.  **File system operations**: Use `CML::IOEvents` or Crystal's `File`/`Dir`
4.  **Path operations**: Use Crystal's `File` and `Path` methods directly

Many OS operations in Crystal are synchronous; use `CML.spawn` to run them in a separate fiber if needed.

## See Also

*   [OS.IO Documentation](os-io.md) - I/O event operations
*   [OS.Process Documentation](os-process.md) - Process operations
*   [Crystal CML Manual](../cml_manual.md) - High-level overview
*   [SML/NJ OS Documentation](https://www.smlnj.org/doc/) - Original documentation

---

*Adapted from SML/NJ OS documentation version 1.1 (2003-03-10)*
