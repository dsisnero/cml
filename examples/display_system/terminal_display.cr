require "../../src/cml"
require "./display"

# Terminal-based display system for visualizing the window system
# This implements the DpySystem interface with terminal output

include Geom
include DpySystem
include WSys
include Frame
include Button
include Menu
include WinManager

module TerminalDisplay
  class TerminalBitmap < DpySystem::Bitmap
    getter rect : Geom::Rect
    getter parent : TerminalBitmap?
    getter children : Array(TerminalBitmap)
    getter id : Int32
    getter z_order : Int32
    @screen_buffer : Array(Array(Char))
    @dirty = true

    def z_order=(value : Int32)
      @z_order = value
    end

    @@next_id = 0

    def initialize(@rect : Geom::Rect, @parent : TerminalBitmap? = nil)
      @id = @@next_id
      @@next_id += 1
      @children = [] of TerminalBitmap
      @z_order = @id
      @screen_buffer = Array.new(rect.ht) { Array.new(rect.wid, ' ') }

      if parent
        parent.not_nil!.children << self
      end

      # puts "TerminalBitmap##{id} created at #{rect}"
    end

    # Drawing operations
    def draw_line(rop : DpySystem::RasterOp, pt1 : Geom::Point, pt2 : Geom::Point) : Nil
      # Simplified line drawing (Bresenham would be better but we keep it simple)
      # puts "TerminalBitmap##{id}.draw_line(#{rop}, #{pt1}, #{pt2})"

      dx = (pt2.x - pt1.x).abs
      dy = (pt2.y - pt1.y).abs
      steps = Math.max(dx, dy)

      return if steps == 0

      x_inc = (pt2.x - pt1.x).to_f / steps
      y_inc = (pt2.y - pt1.y).to_f / steps

      x = pt1.x.to_f
      y = pt1.y.to_f

      steps.times do |_|
        px = x.to_i
        py = y.to_i

        if px >= 0 && px < @rect.wid && py >= 0 && py < @rect.ht
          char = case rop
                 when DpySystem::RasterOp::SET then '#'
                 when DpySystem::RasterOp::CLR then ' '
                 when DpySystem::RasterOp::XOR then @screen_buffer[py][px] == ' ' ? '#' : ' '
                 else                               '#'
                 end
          @screen_buffer[py][px] = char
        end

        x += x_inc
        y += y_inc
      end

      @dirty = true
    end

    def draw_rect(rop : DpySystem::RasterOp, rect : Geom::Rect) : Nil
      # puts "TerminalBitmap##{id}.draw_rect(#{rop}, #{rect})"

      # Draw rectangle outline
      top_left = Geom::Point.new(rect.x, rect.y)
      top_right = Geom::Point.new(rect.x + rect.wid - 1, rect.y)
      bottom_left = Geom::Point.new(rect.x, rect.y + rect.ht - 1)
      bottom_right = Geom::Point.new(rect.x + rect.wid - 1, rect.y + rect.ht - 1)

      draw_line(rop, top_left, top_right)
      draw_line(rop, top_right, bottom_right)
      draw_line(rop, bottom_right, bottom_left)
      draw_line(rop, bottom_left, top_left)

      @dirty = true
    end

    def fill_rect(rop : DpySystem::RasterOp, texture : DpySystem::Texture, rect : Geom::Rect) : Nil
      # puts "TerminalBitmap##{id}.fill_rect(#{rop}, #{texture}, #{rect})"

      char = case rop
             when DpySystem::RasterOp::SET
               case texture
               when DpySystem::SolidTexture   then '#'
               when DpySystem::PatternTexture then '%'
               else                                '#'
               end
             when DpySystem::RasterOp::CLR then ' '
             when DpySystem::RasterOp::XOR then 'X'
             else                               '#'
             end

      rect.y.upto(rect.y + rect.ht - 1) do |y|
        rect.x.upto(rect.x + rect.wid - 1) do |x|
          if x >= 0 && x < @rect.wid && y >= 0 && y < @rect.ht
            @screen_buffer[y][x] = char
          end
        end
      end

      @dirty = true
    end

    def bitblt(dst : DpySystem::Bitmap, rop : DpySystem::RasterOp, pt : Geom::Point, src : DpySystem::Bitmap, src_rect : Geom::Rect) : Nil
      # puts "TerminalBitmap##{id}.bitblt(dst, #{rop}, #{pt}, src, #{src_rect})"
      # Simplified: just mark as dirty
      @dirty = true
    end

    def draw_text(rop : DpySystem::RasterOp, pt : Geom::Point, text : String) : Nil
      # puts "TerminalBitmap##{id}.draw_text(#{rop}, #{pt}, #{text.inspect})"

      text.each_char_with_index do |ch, i|
        x = pt.x + i
        y = pt.y

        if x >= 0 && x < @rect.wid && y >= 0 && y < @rect.ht
          @screen_buffer[y][x] = ch
        end
      end

      @dirty = true
    end

    def string_size(text : String) : {wid: Int32, ht: Int32, ascent: Int32}
      {wid: text.size, ht: 1, ascent: 1}
    end

    # Bitmap operations
    def mk_bitmap(rect : Geom::Rect) : DpySystem::Bitmap
      TerminalBitmap.new(rect, self)
    end

    def to_front : Nil
      # puts "TerminalBitmap##{id}.to_front"
      if parent = @parent
        parent.children.delete(self)
        parent.children << self
        @z_order = parent.children.size
      end
      @dirty = true
    end

    def to_back : Nil
      # puts "TerminalBitmap##{id}.to_back"
      if parent = @parent
        parent.children.delete(self)
        parent.children.unshift(self)
        @z_order = 0
        parent.children.each_with_index do |child, idx|
          child.z_order = idx
        end
      end
      @dirty = true
    end

    def move(pt : Geom::Point) : Nil
      # puts "TerminalBitmap##{id}.move(#{pt})"
      @rect = Geom::Rect.new(pt.x, pt.y, @rect.wid, @rect.ht)
      @dirty = true
      to_front
    end

    def delete : Nil
      # puts "TerminalBitmap##{id}.delete"
      if parent = @parent
        parent.children.delete(self)
      end
      @children.each(&.delete)
      @dirty = true
    end

    def same?(other : DpySystem::Bitmap) : Bool
      object_id == other.object_id
    end

    def bitmap_rect : Geom::Rect
      @rect
    end

    def clr : Nil
      # puts "TerminalBitmap##{id}.clr"
      @screen_buffer = Array.new(@rect.ht) { Array.new(@rect.wid, ' ') }
      @dirty = true
    end

    # Terminal-specific methods
    def render_to_terminal(screen : Array(Array(Char)), offset_x = 0, offset_y = 0)
      # Always render self (root bitmap needs to show border/title)
      @rect.ht.times do |buf_y|
        @rect.wid.times do |buf_x|
          screen_char = @screen_buffer[buf_y][buf_x]
          screen_y = offset_y + @rect.y + buf_y
          screen_x = offset_x + @rect.x + buf_x

          if screen_y >= 0 && screen_y < screen.size &&
             screen_x >= 0 && screen_x < screen[screen_y].size
            screen[screen_y][screen_x] = screen_char
          end
        end
      end
      @dirty = false

      # Render children in z-order (always)
      @children.sort_by(&.z_order).each do |child|
        child.render_to_terminal(screen, offset_x + @rect.x, offset_y + @rect.y)
      end
    end

    def mark_dirty
      @dirty = true
    end
  end

  class TerminalDisplaySystem
    @root_bitmap : TerminalBitmap
    @mouse_chan : CML::Chan(DpySystem::MouseMsg)
    @kbd_chan : CML::Chan(DpySystem::KeyPress)
    @screen : Array(Array(Char))
    @screen_width : Int32
    @screen_height : Int32
    @mouse_pos : Geom::Point
    @mouse_btn : Bool
    @running = true

    def initialize(width = 80, height = 24, title = "CML Terminal Display")
      @screen_width = width
      @screen_height = height
      @screen = Array.new(height) { Array.new(width, ' ') }
      @root_bitmap = TerminalBitmap.new(Geom::Rect.new(0, 0, width, height))
      @mouse_chan = CML::Chan(DpySystem::MouseMsg).new
      @kbd_chan = CML::Chan(DpySystem::KeyPress).new
      @mouse_pos = Geom::Point.new(width // 2, height // 2)
      @mouse_btn = false
      @frame_count = 0

      puts "Terminal Display System initialized: #{width}x#{height}"
      puts "Move mouse with WASD keys, click with space, create windows with 'c', quit with 'q'"

      # Draw border
      @root_bitmap.draw_rect(DpySystem::RasterOp::SET, Geom::Rect.new(0, 0, width, height))
      @root_bitmap.draw_text(DpySystem::RasterOp::SET, Geom::Point.new(2, 0), title)
    end

    def display(name : String?) : {dpy: DpySystem::Bitmap, mouse: CML::Event(DpySystem::MouseMsg), kbd: CML::Event(DpySystem::KeyPress)}
      # Start input thread
      spawn_input_thread

      {
        dpy:   @root_bitmap,
        mouse: @mouse_chan.recv_evt,
        kbd:   @kbd_chan.recv_evt,
      }
    end

    def spawn_input_thread
      # Simple input handling
      spawn do
        while @running
          update_display

          # Simple non-blocking read
          STDIN.read_timeout = 0.01.seconds
          begin
            if ch = STDIN.read_char
              handle_char(ch)
            end
          rescue IO::TimeoutError
            # No input available, continue
          end
          sleep 0.05.seconds
        end
      end
    end

    def update_display
      @frame_count += 1
      STDERR.puts "Frame #{@frame_count}" if @frame_count % 10 == 0
      # Clear screen
      # print "\e[H\e[2J" # Clear terminal

      # Create fresh screen buffer
      @screen = Array.new(@screen_height) { Array.new(@screen_width, ' ') }

      # Render bitmap hierarchy
      @root_bitmap.render_to_terminal(@screen)

      # Draw mouse cursor
      mx = @mouse_pos.x
      my = @mouse_pos.y
      if mx >= 0 && mx < @screen_width && my >= 0 && my < @screen_height
        cursor_char = @mouse_btn ? 'X' : '+'
        @screen[my][mx] = cursor_char
      end

      # Display screen
      @screen.each_with_index do |row, y|
        print "\e[#{y + 1};1H\e[K" # Move to line y+1, column 1 and clear line
        row.each do |ch|
          print ch
        end
      end

      # Display status line
      status_y = @screen_height
      print "\e[#{status_y + 1};1H\e[K"
      print "Mouse: (#{@mouse_pos.x}, #{@mouse_pos.y}) #{@mouse_btn ? "DOWN" : "UP"} | "
      print "Windows: #{count_windows} | "
      print "Commands: wasd=move, space=click, c=create window, q=quit"

      STDOUT.flush
    end

    def handle_char(ch : Char)
      STDERR.puts "Key: #{ch.inspect}"
      case ch
      when 'q'
        @running = false
        @kbd_chan.send(DpySystem::KeyPress.new('q'))
      when 'c'
        # Create a new window
        create_demo_window
      when ' '
        # Mouse click
        @mouse_btn = !@mouse_btn
        @mouse_chan.send(DpySystem::MouseMsg.new(@mouse_btn, @mouse_pos))
      when 'w', 'W'
        # Up
        @mouse_pos = Geom::Point.new(@mouse_pos.x, [@mouse_pos.y - 1, 0].max)
        @mouse_chan.send(DpySystem::MouseMsg.new(@mouse_btn, @mouse_pos))
      when 's', 'S'
        # Down
        @mouse_pos = Geom::Point.new(@mouse_pos.x, [@mouse_pos.y + 1, @screen_height - 1].min)
        @mouse_chan.send(DpySystem::MouseMsg.new(@mouse_btn, @mouse_pos))
      when 'd', 'D'
        # Right
        @mouse_pos = Geom::Point.new([@mouse_pos.x + 1, @screen_width - 1].min, @mouse_pos.y)
        @mouse_chan.send(DpySystem::MouseMsg.new(@mouse_btn, @mouse_pos))
      when 'a', 'A'
        # Left
        @mouse_pos = Geom::Point.new([@mouse_pos.x - 1, 0].max, @mouse_pos.y)
        @mouse_chan.send(DpySystem::MouseMsg.new(@mouse_btn, @mouse_pos))
      else
        @kbd_chan.send(DpySystem::KeyPress.new(ch))
      end
    end

    def create_demo_window
      # Create a demo window with a button
      x = rand(5..(@screen_width - 30))
      y = rand(5..(@screen_height - 10))
      width = 20 + rand(10)
      height = 8 + rand(5)

      window_bm = @root_bitmap.mk_bitmap(Geom::Rect.new(x, y, width, height))
      window_bm.draw_rect(DpySystem::RasterOp::SET, Geom::Rect.new(0, 0, width, height))
      window_bm.draw_text(DpySystem::RasterOp::SET, Geom::Point.new(2, 1), "Window #{window_bm.id}")
      window_bm.draw_text(DpySystem::RasterOp::SET, Geom::Point.new(2, 2), "#{width}x#{height}")

      # Draw a button
      button_rect = Geom::Rect.new(2, 4, width - 4, 3)
      window_bm.draw_rect(DpySystem::RasterOp::SET, button_rect)
      window_bm.draw_text(DpySystem::RasterOp::SET, Geom::Point.new(4, 5), "Button")

      # puts "Created window #{window_bm.id} at (#{x}, #{y})"
    end

    def count_windows
      count = 0
      stack = [@root_bitmap]
      while bm = stack.pop?
        count += bm.children.size
        stack.concat(bm.children)
      end
      count
    end

    def stop
      @running = false
    end
  end

  # Terminal-based WinMap implementation
  class TerminalWinMap(T) < WinMap(T)
    @root_env : WSys::WinEnv
    @root_data : T
    @windows : Array({WSys::WinEnv, T})

    def initialize(@root_env : WSys::WinEnv, @root_data : T)
      @windows = [] of {WSys::WinEnv, T}
    end

    def self.mk_win_map(root_env : WSys::WinEnv, data : T) : WinMap(T)
      TerminalWinMap(T).new(root_env, data)
    end

    def parent : {WSys::WinEnv, T}
      {@root_env, @root_data}
    end

    def insert(wenv : WSys::WinEnv, data : T) : Nil
      @windows << {wenv, data}
      # puts "TerminalWinMap: inserted window #{data}"
    end

    def delete(wenv : WSys::WinEnv) : Nil
      @windows.reject! { |(env, _)| env.same?(wenv) }
      # puts "TerminalWinMap: deleted window"
    end

    def list_all : Array({WSys::WinEnv, T})
      @windows.dup
    end

    def to_front(wenv : WSys::WinEnv) : Nil
      if idx = @windows.index { |(env, _)| env.same?(wenv) }
        entry = @windows.delete_at(idx)
        @windows << entry
        # puts "TerminalWinMap: window brought to front"
      end
    end

    def to_back(wenv : WSys::WinEnv) : Nil
      if idx = @windows.index { |(env, _)| env.same?(wenv) }
        entry = @windows.delete_at(idx)
        @windows.unshift(entry)
        # puts "TerminalWinMap: window sent to back"
      end
    end

    def move(wenv : WSys::WinEnv, pt : Geom::Point) : Nil
      # puts "TerminalWinMap: move window to #{pt}"
    end

    def map_mouse(msg : DpySystem::MouseMsg) : {DpySystem::MouseMsg, WSys::WinEnv, T}
      # Find window containing mouse
      @windows.reverse_each do |(env, data)|
        rect = env.bmap.bitmap_rect
        if msg.pos.in_rect?(rect)
          # Translate coordinates to window space
          translated = DpySystem::MouseMsg.trans(Geom::Point.new(rect.x, rect.y), msg)
          return {translated, env, data}
        end
      end

      # Return root if no window found
      {msg, @root_env, @root_data}
    end

    def find_by_pt(pt : Geom::Point) : {WSys::WinEnv, T}
      @windows.reverse_each do |(env, data)|
        rect = env.bmap.bitmap_rect
        return {env, data} if pt.in_rect?(rect)
      end

      {@root_env, @root_data}
    end

    def find_by_env(wenv : WSys::WinEnv) : T
      @windows.each do |(env, data)|
        return data if env.same?(wenv)
      end
      @root_data
    end
  end
end

# Override DpySystem.display to use terminal display
module DpySystem
  def self.display(name : String?) : {dpy: Bitmap, mouse: CML::Event(MouseMsg), kbd: CML::Event(KeyPress)}
    term_display = TerminalDisplay::TerminalDisplaySystem.new(80, 24, "CML Terminal Window System")
    term_display.display(name)
  end
end

# Override WinMap.mk_win_map to use terminal implementation
class WinMap(T)
  def self.mk_win_map(root_env : WSys::WinEnv, data : T) : WinMap(T)
    TerminalDisplay::TerminalWinMap(T).new(root_env, data)
  end
end

# Demo program
if PROGRAM_NAME.includes?("terminal_display")
  puts "=== TERMINAL DISPLAY VERSION ==="
  puts "=== Crystal CML Terminal Window System Demo ==="
  puts "This demo shows a terminal-based window system with mouse simulation."
  puts "Use arrow keys to move the mouse cursor (+)."
  puts "Press space to click (cursor becomes X when clicked)."
  puts "Press 'c' to create new windows."
  puts "Press 'q' to quit."
  puts ""
  puts "Starting window manager..."

  # Create root environment using terminal display
  dpy_info = DpySystem.display(nil)
  root_env = WSys::WinEnv.mk_env(dpy_info[:dpy])

  # Define a simple client that creates a button
  client = ->(env : WSys::WinEnv) {
    # Create a button in this window
    button_env = Button.mk_button("Click me!", -> {
      # puts "Button clicked! (in real system this would trigger)"
    }, env)

    # Draw some content
    bmap = env.bmap
    bmap.draw_text(DpySystem::RasterOp::SET, Geom::Point.new(2, 2), "Client Window")
    bmap.draw_text(DpySystem::RasterOp::SET, Geom::Point.new(2, 3), "Press space on button")

    nil
  }

  clients = [
    {name: "Demo Window 1", size: Geom::Rect.new(x: 10, y: 5, wid: 30, ht: 8), realize: client},
    {name: "Demo Window 2", size: Geom::Rect.new(x: 45, y: 5, wid: 30, ht: 8), realize: client},
  ]

  # puts "Starting window manager with #{clients.size} initial clients..."

  # Start window manager (spawns fibers)
  WinManager.win_manager(root_env, clients)

  # Create windows immediately (bypass menu system for demo)
  spawn do
    sleep 0.1.seconds # Let window manager initialize

    # Create a simple window map to use create_child
    wmap = WinMap({name: String, frame: Frame::Frame?}).mk_win_map(root_env, {name: "root", frame: nil})

    clients.each_with_index do |client, _|
      sleep 0.2.seconds
      # puts "Creating window #{i+1}..."

      # Create the window using WinManager.create_child
      frame = WinManager.create_child(wmap, client[:name], client[:size], client[:realize])

      # Draw something in the window immediately
      env = Frame.frame_env(frame)
      bmap = env.bmap
      bmap.draw_text(DpySystem::RasterOp::SET, Geom::Point.new(2, 1), client[:name])
      bmap.draw_text(DpySystem::RasterOp::SET, Geom::Point.new(2, 2), "Auto-created")
      bmap.draw_rect(DpySystem::RasterOp::SET, Geom::Rect.new(0, 0, client[:size].wid, client[:size].ht))
    end
  end

  puts "Window manager started. Terminal display active."
  puts "The main thread will sleep while display runs in background."
  puts "Press Ctrl+C or 'q' in terminal to exit."

  # Keep main thread alive
  loop do
    sleep 1.second
  end
end
