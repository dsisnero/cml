# Terminal Display System

A terminal-based implementation of the Chapter 8 "Concurrent Window System" from *Concurrent Programming in ML*.

## Overview

This file provides a terminal-based visualization of the CML window system. It implements the `DpySystem` interface using ASCII characters to render windows, mouse cursor, and mouse movements in a terminal.

## Features

- **Terminal rendering**: Windows are drawn as ASCII boxes with borders
- **Mouse simulation**: Move cursor with WASD keys, click with spacebar
- **Interactive window creation**: Press 'c' to create new windows
- **Real-time display**: Updates the terminal 20 times per second
- **Window hierarchy**: Supports nested windows with z-ordering

## How It Works

1. **TerminalBitmap**: Implements the `DpySystem::Bitmap` abstract class
   - Maintains a character buffer for rendering
   - Supports drawing operations (lines, rectangles, text)
   - Manages parent-child relationships and z-ordering

2. **TerminalDisplaySystem**: Main display driver
   - Creates root bitmap and input channels
   - Renders the display hierarchy to terminal
   - Handles keyboard input for mouse simulation

3. **TerminalWinMap**: Window mapping implementation
   - Tracks window positions and stacking order
   - Maps mouse coordinates to appropriate windows

## Building and Running

```bash
cd /path/to/cml
crystal build examples/display_system/terminal_display.cr -o terminal_display
./terminal_display
```

## Controls

- **W/A/S/D**: Move mouse cursor up/left/down/right
- **Space**: Toggle mouse button (click)
- **C**: Create a new demo window
- **Q**: Quit the application

## Architecture Notes

The terminal display system demonstrates:

1. **Concurrent Architecture**: Same three-thread architecture as the original (controller, keyboard router, command-in router)
2. **Abstract Interface Implementation**: Shows how to implement the abstract `DpySystem` interface
3. **Event-Driven Input**: Mouse and keyboard events are delivered via CML channels
4. **Hierarchical Rendering**: Windows are rendered in z-order with proper coordinate translation

## Limitations

1. **Terminal Requirements**: Requires a terminal that supports ANSI escape codes
2. **Simple Graphics**: Only basic character-based rendering
3. **Input Handling**: Uses simple polling rather than raw terminal mode in non-interactive contexts
4. **Performance**: Full screen redraw on every update (not optimized)

## Integration with CML

The terminal display seamlessly integrates with the existing CML window system:

- Overrides `DpySystem.display()` to provide terminal-based implementation
- Overrides `WinMap.mk_win_map()` to use terminal-specific window mapping
- Maintains compatibility with all existing components (Frame, Button, Menu, WinManager)

## Example Output

```
=== Crystal CML Terminal Window System Demo ===
Terminal Display System initialized: 80x24
Move mouse with WASD keys, click with space, create windows with 'c', quit with 'q'

+------------------------------------------------------------------------------+
|                              CML Terminal Window System                      |
|                                                                              |
|        +-------------------+                         +-------------------+   |
|        | Window 1          |                         | Window 2          |   |
|        | 30x8              |                         | 25x10             |   |
|        |                   |                         |                   |   |
|        |     [Button]      |                         |     [Button]      |   |
|        +-------------------+                         +-------------------+   |
|                                                                              |
|                                        +                                     |
|                                                                              |
+------------------------------------------------------------------------------+
Mouse: (40, 12) UP | Windows: 2 | Commands: wasd=move, space=click, c=create window, q=quit
```