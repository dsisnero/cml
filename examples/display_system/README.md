# Crystal CML Window System (Chapter 8 Conversion)

This directory contains a Crystal implementation of the "Concurrent Window System" example from Chapter 8 of the book *Concurrent Programming in ML* by John H. Reppy.

## Overview

The original ML code demonstrates a toy window manager built using Concurrent ML (CML) primitives. This Crystal version adapts the same architecture using the Crystal CML library (`src/cml.cr`).

## Components

The implementation consists of the following modules, each corresponding to a section in Chapter 8:

1. **Geom** – Geometry types (points and rectangles) and operations.
2. **DpySystem** – Abstract display system interface (bitmap, raster operations, mouse/keyboard events).
3. **WSys** – Window system environment and channel management.
4. **Frame** – Window frames with highlighting.
5. **Button** – Interactive button component.
6. **Menu** – Pop‑up menu component.
7. **WinMap** – Window mapping and stacking order.
8. **WinManager** – The main window manager with three coordinating threads (controller, keyboard router, command‑in router).

Additionally, a **Mock** module provides concrete implementations of the abstract `Bitmap` and `WinMap` classes, allowing the example to run without a real graphical backend.

## Key Differences from the ML Original

* **Recursive Proc Definitions** – ML allows mutually recursive functions to be defined naturally. In Crystal we used `uninitialized Proc` forward declarations (see `WinManager`).
* **Module Aliases** – The ML code uses local aliases `G`, `D`, `W` for `Geom`, `DpySystem`, `WSys`. In Crystal we used full module names or explicit `include`.
* **CML API Names** – The Crystal CML library uses slightly different method names:
  * `.take` → `.m_take`
  * `.put` → `.m_put`
  * `.get_evt` → `.i_get_evt`
  * `.send` (on channels) is unchanged.
* **Tuple Pattern Matching** – ML’s pattern‑matching on tuples was converted to explicit `if`/`elsif` logic or tuple destructuring.
* **Abstract Classes** – ML signatures become abstract classes in Crystal; missing methods raise `NotImplementedError`.
* **Mock Implementations** – The original relies on a real display system; our mocks print console messages instead of performing graphics operations.

## Running the Examples

### Main Demo (Mock Display)
Compile and run the main demo:

```bash
cd /path/to/cml
crystal build examples/display_system/display.cr -o display
./display
```

The demo will start the window manager, create a root environment, and run for two seconds before shutting down. Operations are logged to the console.

### Terminal Display Demo
For a visual terminal-based demonstration:

```bash
crystal build examples/display_system/terminal_display.cr -o terminal_display
./terminal_display
```

This shows a terminal visualization with mouse simulation (WASD to move, space to click).

### Simple Terminal Demo
For a simpler demonstration of the concepts:

```bash
crystal build examples/display_system/simple_terminal_demo.cr -o simple_terminal_demo
./simple_terminal_demo
```

This shows basic terminal graphics without the full window manager complexity.

## Testing

A basic spec file (`spec/display_spec.cr`) verifies that each component can be instantiated and that the geometry and channel operations work as expected. Run the tests with:

```bash
crystal spec spec/display_spec.cr
```

## Notes

* This implementation is a *direct translation* of the ML code, preserving the original architecture and concurrency patterns. It is intended as a proof‑of‑concept and a demonstration of how CML primitives can be used to build a non‑trivial concurrent system in Crystal.
* The window manager uses the “click‑to‑type” input routing policy described in Section 8.4.2.
* The mock display system does not simulate overlapping windows or actual graphics; it only prints method calls.

## Future Work

* Connect the display system to a real graphics backend (e.g., via LibSDL or a simple bitmap renderer).
* Extend the example with more UI components (text fields, sliders, etc.).
* Write more comprehensive integration tests that simulate user interactions.

## References

* Reppy, John H. *Concurrent Programming in ML*. Cambridge University Press, 1999.
* The Crystal CML library documentation in `docs/`.