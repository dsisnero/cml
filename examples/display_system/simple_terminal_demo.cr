require "../../src/cml"
require "./display"

# A simple demo that shows the terminal display system basics
# without the full window manager complexity

include Geom
include DpySystem
include WSys

module SimpleTerminal
  # Simple terminal bitmap that draws to console
  class SimpleBitmap < DpySystem::Bitmap
    getter rect : Geom::Rect
    @buffer : Array(Array(Char))

    def initialize(@rect : Geom::Rect)
      @buffer = Array.new(rect.ht) { Array.new(rect.wid, ' ') }
      # puts "SimpleBitmap created: #{rect}"
    end

    def draw_line(rop : DpySystem::RasterOp, pt1 : Geom::Point, pt2 : Geom::Point) : Nil
      # Simple line drawing
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
          @buffer[py][px] = '#'
        end
        x += x_inc
        y += y_inc
      end
    end

    def draw_rect(rop : DpySystem::RasterOp, rect : Geom::Rect) : Nil
      # Draw rectangle outline
      (rect.x...rect.x + rect.wid).each do |x|
        if x >= 0 && x < @rect.wid
          y1 = rect.y
          y2 = rect.y + rect.ht - 1
          if y1 >= 0 && y1 < @rect.ht
            @buffer[y1][x] = '#'
          end
          if y2 >= 0 && y2 < @rect.ht
            @buffer[y2][x] = '#'
          end
        end
      end

      (rect.y...rect.y + rect.ht).each do |y|
        if y >= 0 && y < @rect.ht
          x1 = rect.x
          x2 = rect.x + rect.wid - 1
          if x1 >= 0 && x1 < @rect.wid
            @buffer[y][x1] = '#'
          end
          if x2 >= 0 && x2 < @rect.wid
            @buffer[y][x2] = '#'
          end
        end
      end
    end

    def fill_rect(rop : DpySystem::RasterOp, texture : DpySystem::Texture, rect : Geom::Rect) : Nil
      rect.y.upto(rect.y + rect.ht - 1) do |y|
        rect.x.upto(rect.x + rect.wid - 1) do |x|
          if x >= 0 && x < @rect.wid && y >= 0 && y < @rect.ht
            @buffer[y][x] = texture.is_a?(DpySystem::SolidTexture) ? '#' : '%'
          end
        end
      end
    end

    def bitblt(dst : DpySystem::Bitmap, rop : DpySystem::RasterOp, pt : Geom::Point, src : DpySystem::Bitmap, src_rect : Geom::Rect) : Nil
      # Not implemented for simple demo
    end

    def draw_text(rop : DpySystem::RasterOp, pt : Geom::Point, text : String) : Nil
      text.each_char_with_index do |ch, i|
        x = pt.x + i
        y = pt.y
        if x >= 0 && x < @rect.wid && y >= 0 && y < @rect.ht
          @buffer[y][x] = ch
        end
      end
    end

    def string_size(text : String) : {wid: Int32, ht: Int32, ascent: Int32}
      {wid: text.size, ht: 1, ascent: 1}
    end

    def mk_bitmap(rect : Geom::Rect) : DpySystem::Bitmap
      SimpleBitmap.new(rect)
    end

    def to_front : Nil
      # Not needed for simple demo
    end

    def to_back : Nil
      # Not needed for simple demo
    end

    def move(pt : Geom::Point) : Nil
      @rect = Geom::Rect.new(pt.x, pt.y, @rect.wid, @rect.ht)
    end

    def delete : Nil
      # Not needed for simple demo
    end

    def same?(other : DpySystem::Bitmap) : Bool
      object_id == other.object_id
    end

    def bitmap_rect : Geom::Rect
      @rect
    end

    def clr : Nil
      @buffer = Array.new(@rect.ht) { Array.new(@rect.wid, ' ') }
    end

    def render
      print "\e[H" # move cursor to home
      @buffer.each_with_index do |row, y|
        print "\e[#{y + 1};1H\e[K"
        row.each do |ch|
          print ch
        end
      end
      STDOUT.flush
    end
  end

  # Simple display system
  class SimpleDisplay
    @bitmap : SimpleBitmap
    @mouse_chan : CML::Chan(DpySystem::MouseMsg)
    @kbd_chan : CML::Chan(DpySystem::KeyPress)
    @mouse_pos : Geom::Point
    @mouse_btn : Bool

    def initialize(width = 40, height = 20)
      @bitmap = SimpleBitmap.new(Geom::Rect.new(0, 0, width, height))
      @mouse_chan = CML::Chan(DpySystem::MouseMsg).new
      @kbd_chan = CML::Chan(DpySystem::KeyPress).new
      @mouse_pos = Geom::Point.new(width // 2, height // 2)
      @mouse_btn = false

      # Draw border and title
      @bitmap.draw_rect(DpySystem::RasterOp::SET, Geom::Rect.new(0, 0, width, height))
      @bitmap.draw_text(DpySystem::RasterOp::SET, Geom::Point.new(2, 0), "Simple Terminal Demo")

      puts "Simple Terminal Demo initialized: #{width}x#{height}"
      puts "Use WASD to move, SPACE to click, Q to quit"
    end

    def run
      # Create a simple window
      create_window(5, 3, 20, 8, "Window 1")
      create_window(15, 8, 20, 8, "Window 2")

      # Main loop
      loop do
        update_display
        handle_input
        sleep 0.1.seconds
      end
    end

    def create_window(x, y, width, height, title)
      # Draw window
      @bitmap.draw_rect(DpySystem::RasterOp::SET, Geom::Rect.new(x, y, width, height))
      @bitmap.draw_text(DpySystem::RasterOp::SET, Geom::Point.new(x + 2, y + 1), title)

      # Draw a simple button
      @bitmap.draw_rect(DpySystem::RasterOp::SET, Geom::Rect.new(x + 2, y + 4, width - 4, 3))
      @bitmap.draw_text(DpySystem::RasterOp::SET, Geom::Point.new(x + 4, y + 5), "Button")
    end

    def update_display
      # Draw mouse cursor
      temp_buffer = @bitmap.@buffer.map(&.dup)
      mx = @mouse_pos.x
      my = @mouse_pos.y
      rect = @bitmap.bitmap_rect
      if mx >= 0 && mx < rect.wid && my >= 0 && my < rect.ht
        temp_buffer[my][mx] = @mouse_btn ? 'X' : '+'
      end

      # Render
      print "\e[H\e[2J"
      temp_buffer.each do |row|
        row.each do |ch|
          print ch
        end
        puts
      end

      # Status
      puts "Mouse: (#{mx}, #{my}) #{@mouse_btn ? "DOWN" : "UP"} | Press Q to quit"
      STDOUT.flush
    end

    def handle_input
      # Simple input handling
      STDIN.read_timeout = 0.01.seconds
      if ch = STDIN.read_char
        case ch.downcase
        when 'q'
          puts "Quitting..."
          exit 0
        when 'w'
          @mouse_pos = Geom::Point.new(@mouse_pos.x, [@mouse_pos.y - 1, 0].max)
        when 's'
          rect = @bitmap.bitmap_rect
          @mouse_pos = Geom::Point.new(@mouse_pos.x, [@mouse_pos.y + 1, rect.ht - 1].min)
        when 'a'
          @mouse_pos = Geom::Point.new([@mouse_pos.x - 1, 0].max, @mouse_pos.y)
        when 'd'
          rect = @bitmap.bitmap_rect
          @mouse_pos = Geom::Point.new([@mouse_pos.x + 1, rect.wid - 1].min, @mouse_pos.y)
        when ' '
          @mouse_btn = !@mouse_btn
          # puts "Mouse #{@mouse_btn ? "pressed" : "released"} at (#{@mouse_pos.x}, #{@mouse_pos.y})"
        end
      end
    end
  end
end

# Run the demo
if PROGRAM_NAME.includes?("simple_terminal_demo")
  puts "=== Simple Terminal Display Demo ==="
  puts "This demonstrates basic terminal display concepts from Chapter 8"
  puts ""

  demo = SimpleTerminal::SimpleDisplay.new(50, 25)
  demo.run
end
