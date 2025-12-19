# Chapter 8: A Concurrent Window System - Crystal version
# Converted from Cambridge Concurrent Programming in ML
#
# This file contains the complete code from Chapter 8, organized as a single Crystal file.
# Dependencies: CML library (../src/cml)
#
# The implementations of DpySystem, WSys, and WinMap are omitted as in the book.
# This is a skeleton that demonstrates the architecture and type signatures.

require "../../src/cml"

# Geom module - geometry types and operations
module Geom
  # Point struct
  struct Point
    getter x : Int32
    getter y : Int32

    def initialize(@x : Int32, @y : Int32)
    end

    def self.origin : Point
      Point.new(0, 0)
    end

    def add(other : Point) : Point
      Point.new(@x + other.x, @y + other.y)
    end

    def sub(other : Point) : Point
      Point.new(@x - other.x, @y - other.y)
    end

    def less?(other : Point) : Bool
      @x < other.x && @y < other.y
    end

    def in_rect?(rect : Rect) : Bool
      rect.x <= @x && @x < rect.x + rect.wid && rect.y <= @y && @y < rect.y + rect.ht
    end
  end

  # Rect struct
  struct Rect
    getter x : Int32
    getter y : Int32
    getter wid : Int32
    getter ht : Int32

    def initialize(@x : Int32, @y : Int32, @wid : Int32, @ht : Int32)
    end

    def origin : Point
      Point.new(@x, @y)
    end

    def move(pt : Point) : Rect
      Rect.new(pt.x, pt.y, @wid, @ht)
    end

    def inset(n : Int32) : Rect
      Rect.new(@x + n, @y + n, @wid - 2*n, @ht - 2*n)
    end

    def add(pt : Point) : Rect
      Rect.new(@x + pt.x, @y + pt.y, @wid, @ht)
    end

    def sub(pt : Point) : Rect
      Rect.new(@x - pt.x, @y - pt.y, @wid, @ht)
    end

    def within(other : Rect) : Rect
      x = if other.x < @x
            @x
          elsif other.x + other.wid > @x + @wid
            @x + @wid - other.wid
          else
            other.x
          end
      y = if other.y < @y
            @y
          elsif other.y + other.ht > @y + @ht
            @y + @ht - other.ht
          else
            other.y
          end
      Rect.new(x, y, other.wid, other.ht)
    end
  end
end

# Alias for convenience
G = Geom

# Display System module
module DpySystem
  # Abstract bitmap type
  abstract class Bitmap
    # Graphics operations
    abstract def draw_line(rop : RasterOp, pt1 : Geom::Point, pt2 : Geom::Point) : Nil
    abstract def draw_rect(rop : RasterOp, rect : Geom::Rect) : Nil
    abstract def fill_rect(rop : RasterOp, texture : Texture, rect : Geom::Rect) : Nil
    abstract def bitblt(dst : Bitmap, rop : RasterOp, pt : Geom::Point, src : Bitmap, src_rect : Geom::Rect) : Nil
    abstract def draw_text(rop : RasterOp, pt : Geom::Point, text : String) : Nil
    abstract def string_size(text : String) : {wid: Int32, ht: Int32, ascent: Int32}

    # Bitmap operations
    abstract def mk_bitmap(rect : Geom::Rect) : Bitmap
    abstract def to_front : Nil
    abstract def to_back : Nil
    abstract def move(pt : Geom::Point) : Nil
    abstract def delete : Nil
    abstract def same?(other : Bitmap) : Bool
    abstract def bitmap_rect : Geom::Rect
    abstract def clr : Nil
  end

  # Raster operations enum
  enum RasterOp
    CPY
    XOR
    OR
    AND
    CLR
    SET
  end

  # Texture type
  alias Texture = SolidTexture | PatternTexture

  struct SolidTexture
  end

  struct PatternTexture
    getter pattern : Array(UInt32)

    def initialize(@pattern : Array(UInt32))
    end
  end

  SOLID = SolidTexture.new

  # Mouse message
  struct MouseMsg
    getter btn : Bool # true = down, false = up
    getter pos : Geom::Point

    def initialize(@btn : Bool, @pos : Geom::Point)
    end

    def self.up?(msg : MouseMsg) : Bool
      !msg.btn
    end

    def self.down?(msg : MouseMsg) : Bool
      msg.btn
    end

    def self.pos(msg : MouseMsg) : Geom::Point
      msg.pos
    end

    def self.trans(pt : Geom::Point, msg : MouseMsg) : MouseMsg
      MouseMsg.new(msg.btn, Geom::Point.new(msg.pos.x - pt.x, msg.pos.y - pt.y))
    end
  end

  # Key press
  struct KeyPress
    getter char : Char

    def initialize(@char : Char)
    end

    KEY_DEL = KeyPress.new('\u007F')
    KEY_BS  = KeyPress.new('\u0008')
    KEY_RET = KeyPress.new('\u000D')
    KEY_TAB = KeyPress.new('\u0009')
  end

  # Display initialization
  def self.display(name : String?) : {dpy: Bitmap, mouse: CML::Event(MouseMsg), kbd: CML::Event(KeyPress)}
    raise NotImplementedError.new("DpySystem.display must be implemented")
  end
end

# Alias for convenience
D = DpySystem

# Window System interface
module WSys
  alias Bitmap = DpySystem::Bitmap
  alias MouseMsg = DpySystem::MouseMsg
  alias KeyPress = DpySystem::KeyPress

  # Control message
  struct Cmd
    getter msg : String
    getter rect : Geom::Rect?

    def initialize(@msg : String, @rect : Geom::Rect? = nil)
    end
  end

  # Window environment
  class WinEnv
    getter win : Bitmap
    getter m : CML::Chan(MouseMsg) # mouse channel
    getter k : CML::Chan(KeyPress) # keyboard channel
    getter ci : CML::Chan(Cmd)     # command-in channel
    getter co : CML::Mailbox(Cmd)  # command-out mailbox

    def initialize(@win : Bitmap, @m : CML::Chan(MouseMsg), @k : CML::Chan(KeyPress),
                   @ci : CML::Chan(Cmd), @co : CML::Mailbox(Cmd))
    end

    # Constructor function mkEnv
    def self.mk_env(win : Bitmap) : WinEnv
      WinEnv.new(
        win,
        CML::Chan(MouseMsg).new,
        CML::Chan(KeyPress).new,
        CML::Chan(Cmd).new,
        CML::Mailbox(Cmd).new
      )
    end

    # Realize a window in a rectangle
    def self.realize(bmap : Bitmap, rect : Geom::Rect, &block : WinEnv -> U) : U forall U
      # In the real implementation, this would create a sub-bitmap
      # and run the block with the new environment
      # For now, we'll create a dummy environment
      env = mk_env(bmap.mk_bitmap(rect))
      block.call(env)
    end

    # Accessors
    def bmap : Bitmap
      @win
    end

    def mouse : CML::Chan(MouseMsg)
      @m
    end

    def kbd : CML::Chan(KeyPress)
      @k
    end

    def cmd_in : CML::Chan(Cmd)
      @ci
    end

    def cmd_out : CML::Mailbox(Cmd)
      @co
    end

    def rect : Geom::Rect
      @win.bitmap_rect
    end

    def same?(other : WinEnv) : Bool
      @win.same?(other.win)
    end

    # Sink function - discard messages from a channel
    def self.sink(ch : CML::Chan(T)) : Nil forall T
      spawn do
        loop do
          ch.recv
        end
      end
    end

    # Initialize window system
    def self.init(name : String?) : WinEnv
      dpy_info = DpySystem.display(name)
      mk_env(dpy_info[:dpy])
    end
  end
end

# Alias for convenience
W = WSys

# Frame component
module Frame
  class Frame
    @env : WSys::WinEnv
    @hlight_ch : CML::Chan(Bool)

    def initialize(@env : WSys::WinEnv, @hlight_ch : CML::Chan(Bool))
    end

    FRAME_WID = 2

    def self.mk_frame(realize : WSys::WinEnv -> T, wenv : WSys::WinEnv) : {Frame, T} forall T
      frame_bm = wenv.bmap
      frame_rect = frame_bm.bitmap_rect
      # Adjust for frame border
      frame_rect = Geom::Rect.new(
        x: 0, y: 0,
        wid: frame_rect.wid - 1,
        ht: frame_rect.ht - 1
      )
      highlight_rect = Geom::Rect.new(
        x: 1, y: 1,
        wid: frame_rect.wid - 3,
        ht: frame_rect.ht - 3
      )
      child_rect = Geom::Rect.new(
        x: FRAME_WID, y: FRAME_WID,
        wid: frame_rect.wid - 2*FRAME_WID,
        ht: frame_rect.ht - 2*FRAME_WID
      )

      # Create child environment
      child_env = WSys::WinEnv.new(
        frame_bm.mk_bitmap(child_rect),
        CML::Chan(DpySystem::MouseMsg).new,
        wenv.kbd,
        wenv.cmd_in,
        wenv.cmd_out
      )

      # Mouse translation
      m_trans = ->(msg : DpySystem::MouseMsg) {
        DpySystem::MouseMsg.trans(Geom::Point.new(FRAME_WID, FRAME_WID), msg)
      }

      # Mouse loop thread
      spawn do
        loop do
          msg = child_env.mouse.recv
          translated = m_trans.call(msg)
          wenv.mouse.send(translated)
        end
      end

      hlight_ch = CML::Chan(Bool).new

      # Highlight loop thread
      spawn do
        is_on = false
        loop do
          new_state = hlight_ch.recv
          if is_on && !new_state
            frame_bm.draw_rect(DpySystem::RasterOp::CLR, highlight_rect)
            is_on = false
          elsif !is_on && new_state
            frame_bm.draw_rect(DpySystem::RasterOp::SET, highlight_rect)
            is_on = true
          end
        end
      end

      # Draw frame border
      frame_bm.clr
      frame_bm.draw_rect(DpySystem::RasterOp::SET, frame_rect)

      frame_obj = Frame.new(wenv, hlight_ch)
      {frame_obj, realize.call(child_env)}
    end

    def same?(other : Frame) : Bool
      @env.bmap.same?(other.frame_env.bmap)
    end

    def frame_env : WSys::WinEnv
      @env
    end

    def highlight(on_or_off : Bool) : Nil
      @hlight_ch.send(on_or_off)
    end
  end

  # Helper functions
  def self.frame_wid : Int32
    Frame::FRAME_WID
  end

  def self.mk_frame(realize : WSys::WinEnv -> T, wenv : WSys::WinEnv) : {Frame, T} forall T
    Frame.mk_frame(realize, wenv)
  end

  def self.same_frame(f1 : Frame, f2 : Frame) : Bool
    f1.same?(f2)
  end

  def self.frame_env(frame : Frame) : WSys::WinEnv
    frame.frame_env
  end

  def self.highlight(frame : Frame, on_or_off : Bool) : Nil
    frame.highlight(on_or_off)
  end
end

# Alias for convenience
F = Frame

# Button component
module Button
  def self.mk_button(msg : String, act : -> Nil, wenv : WSys::WinEnv) : WSys::WinEnv
    win = wenv.win
    but_wid = win.bitmap_rect.wid
    but_ht = win.bitmap_rect.ht
    but_rect = win.bitmap_rect.move(Geom::Point.origin)

    # Calculate text position
    size = win.string_size(msg)
    txt_origin = Geom::Point.new(
      Math.max(0, (but_wid - size[:wid]) // 2),
      Math.min(but_ht - 1, ((but_ht - size[:ht]) // 2) + size[:ascent])
    )

    # Mouse state helper
    mouse_state = ->(msg : DpySystem::MouseMsg) {
      {msg.btn, msg.pos.in_rect?(but_rect)}
    }

    # Main loop
    spawn do
      was_in_and_up = false
      loop do
        # Select between mouse and command events
        mouse_evt = CML.wrap(wenv.mouse.recv_evt) do |msg|
          is_dn, is_in = mouse_state.call(msg)
          if was_in_and_up && is_dn && is_in
            act.call
            was_in_and_up = false
          else
            was_in_and_up = !is_dn && is_in
          end
          nil
        end

        cmd_evt = CML.wrap(wenv.cmd_in.recv_evt) do |cmd|
          if cmd.msg == "Delete"
            wenv.cmd_out.send(cmd)
          end
          nil
        end

        CML.select([mouse_evt, cmd_evt])
      end
    end

    # Draw button
    win.draw_rect(DpySystem::RasterOp::SET, Geom::Rect.new(x: 0, y: 0, wid: but_wid - 1, ht: but_ht - 1))
    win.draw_text(DpySystem::RasterOp::CPY, txt_origin, msg)

    # Sink keyboard events
    WSys::WinEnv.sink(wenv.kbd)

    wenv
  end
end

# Popup menu component
module Menu
  ITEM_SEP = 2

  # Item type: tuple of label and value (Tuple(String, T))

  # Item info structure
  struct ItemInfo(T)
    getter lab : String
    getter value : T
    getter pt : Geom::Point
    getter rect : Geom::Rect

    def initialize(@lab : String, @value : T, @pt : Geom::Point, @rect : Geom::Rect)
    end
  end

  # Layout menu items
  def self.layout(win : DpySystem::Bitmap, pt : Geom::Point, items : Array(Tuple(String, T))) : Tuple(Geom::Rect, Array(ItemInfo(T))) forall T
    max_wid = 0
    tot_ht = 0
    posns = [] of {Int32, Int32, Int32} # y, base, ht

    items.each do |(s, _)|
      size = win.string_size(s)
      wid = size[:wid]
      ht = size[:ht]
      ascent = size[:ascent]
      y = tot_ht + ITEM_SEP
      max_wid = Math.max(max_wid, wid)
      tot_ht = y + ht
      posns << {y, y + ascent, ht}
    end

    menu_rect = win.bitmap_rect.within(
      Geom::Rect.new(x: pt.x, y: pt.y, wid: max_wid + 2*ITEM_SEP, ht: tot_ht + ITEM_SEP)
    )

    item_infos = [] of ItemInfo(T)
    items.zip(posns.reverse) do |(s, v), (y, base, ht)|
      item_infos << ItemInfo(T).new(
        s, v,
        Geom::Point.new(x: ITEM_SEP, y: base),
        Geom::Rect.new(x: ITEM_SEP, y: y, wid: max_wid, ht: ht)
      )
    end

    {menu_rect, item_infos}
  end

  # Find which item contains point
  def self.which_item(items : Array(ItemInfo(T)), pt : Geom::Point) : ItemInfo(T)? forall T
    items.find { |item| pt.in_rect?(item.rect) }
  end

  # Display menu and return selected value
  def self.menu(wenv : WSys::WinEnv, pt : Geom::Point, items : Array(Tuple(String, T))) : T? forall T
    win = wenv.win
    menu_rect, item_infos = layout(win, pt, items)
    menu_win = win.mk_bitmap(menu_rect)

    # Draw menu items
    item_infos.each do |item|
      menu_win.draw_text(DpySystem::RasterOp::SET, item.pt, item.lab)
    end

    # Highlight initial item if any
    initial_item = which_item(item_infos, pt)
    if initial_item
      menu_win.fill_rect(DpySystem::RasterOp::XOR, DpySystem::SOLID, initial_item.rect)
    end

    cur_item = initial_item

    # Menu loop
    loop do
      msg = wenv.mouse.recv
      translated_msg = DpySystem::MouseMsg.trans(menu_rect.origin, msg)

      if translated_msg.btn
        # Button down - track highlighting
        new_item = which_item(item_infos, translated_msg.pos)
        if cur_item != new_item
          # Unhighlight old, highlight new
          menu_win.fill_rect(DpySystem::RasterOp::XOR, DpySystem::SOLID, cur_item.rect) if cur_item
          menu_win.fill_rect(DpySystem::RasterOp::XOR, DpySystem::SOLID, new_item.rect) if new_item
          cur_item = new_item
        end
      else
        # Button up - selection
        menu_win.delete
        selected = which_item(item_infos, translated_msg.pos)
        return selected.try &.value
      end
    end
  end
end

# Window Map signature (implementation omitted as in book)
abstract class WinMap(T)
  # Create a new window map with root window and initial data
  def self.mk_win_map(root_env : WSys::WinEnv, data : T) : WinMap(T)
    raise NotImplementedError.new("WinMap(T).mk_win_map must be implemented")
  end

  # Get parent window and its data
  abstract def parent : {WSys::WinEnv, T}

  # Insert a new window with data
  abstract def insert(wenv : WSys::WinEnv, data : T) : Nil

  # Delete a window
  abstract def delete(wenv : WSys::WinEnv) : Nil

  # List all windows with data
  abstract def list_all : Array({WSys::WinEnv, T})

  # Bring window to front
  abstract def to_front(wenv : WSys::WinEnv) : Nil

  # Send window to back
  abstract def to_back(wenv : WSys::WinEnv) : Nil

  # Move window by offset
  abstract def move(wenv : WSys::WinEnv, pt : Geom::Point) : Nil

  # Map mouse message to containing window
  abstract def map_mouse(msg : DpySystem::MouseMsg) : {DpySystem::MouseMsg, WSys::WinEnv, T}

  # Find window containing point
  abstract def find_by_pt(pt : Geom::Point) : {WSys::WinEnv, T}

  # Find data for window
  abstract def find_by_env(wenv : WSys::WinEnv) : T
end

# Window Manager
module WinManager
  # Helper functions that extend frame operations to options
  def self.highlight(frame_opt : Frame::Frame?, on_or_off : Bool) : Nil
    if frame_opt
      Frame.highlight(frame_opt, on_or_off)
    end
  end

  def self.same_frame(f1_opt : Frame::Frame?, f2_opt : Frame::Frame?) : Bool
    if f1_opt && f2_opt
      Frame.same_frame(f1_opt, f2_opt)
    else
      false
    end
  end

  # Main window manager function
  def self.win_manager(root_env : WSys::WinEnv, clients : Array({name: String, size: Geom::Rect, realize: (WSys::WinEnv -> Nil)})) : Nil
    quit_flg = CML::IVar(Nil).new                 # IVar(Nil)
    cur_frame = CML::MVar(Frame::Frame?).new(nil) # MVar(Frame::Frame?) initialized to nil

    # Controller thread
    controller = -> {
      w_map = WinMap({name: String, frame: Frame::Frame?}).mk_win_map(root_env, {name: "", frame: nil})

      # Forward declarations for mutually recursive functions
      mouse_router = uninitialized Proc(Bool, CML::Event({WSys::Cmd, WSys::WinEnv, Frame::Frame}), Nil)
      track_mouse = uninitialized Proc(Nil)
      do_menu = uninitialized Proc(Geom::Point, Nil)

      # Mouse router function (simplified)
      mouse_router = ->(was_dn : Bool, child_cmd_evt : CML::Event({WSys::Cmd, WSys::WinEnv, Frame::Frame})) {
        # Handle mouse messages
        handle_m = ->(msg : DpySystem::MouseMsg) {
          mapped = w_map.map_mouse(msg)
          msg2, wenv, data = mapped
          opt_fr = data[:frame]

          cur = cur_frame.m_take # Removes value from MVar

          if !was_dn && msg.btn # down transition
            if opt_fr.nil?
              # Pattern 1: Down transition, not in any window
              highlight(cur, false)
              cur_frame.m_put(nil)
              do_menu.call(msg.pos)
            elsif cur
              # Pattern 2: Down transition, in a window, has current frame
              cur_fr = cur
              some_fr = opt_fr
              if !same_frame(cur_fr, some_fr)
                highlight(cur_fr, false)
                highlight(some_fr, true)
              end
              wenv.mouse.send(msg2)
              cur_frame.m_put(some_fr)
              mouse_router.call(true, child_cmd_evt)
            else
              # Down transition, in a window, no current frame
              cur_frame.m_put(nil)
              mouse_router.call(msg.btn, child_cmd_evt)
            end
          elsif cur
            # Pattern 3: Not down transition, has current frame
            some_fr = cur
            wenv.mouse.send(msg2)
            cur_frame.m_put(some_fr)
            mouse_router.call(msg.btn, child_cmd_evt)
          else
            # No current frame
            cur_frame.m_put(nil)
            mouse_router.call(msg.btn, child_cmd_evt)
          end
        }

        # Handle child command-in
        handle_ci = ->(cmd_info : {WSys::Cmd, WSys::WinEnv, Frame::Frame}) {
          msg, wenv, fr = cmd_info
          if msg.msg == "Delete"
            current = cur_frame.m_take
            w_map.delete(wenv)
            if same_frame(current, fr)
              cur_frame.m_put(nil)
            else
              cur_frame.m_put(current)
            end
            track_mouse.call
          else
            mouse_router.call(was_dn, child_cmd_evt)
          end
        }

        # Quit function
        quit = -> {
          w_map.list_all.each do |(wenv, _)|
            delete_child(w_map, wenv)
          end
          root_env.cmd_out.send(WSys::Cmd.new("Delete"))
        }

        # Select between mouse, child command, and quit flag
        mouse_evt = CML.wrap(root_env.mouse.recv_evt, &handle_m)
        child_evt = CML.wrap(child_cmd_evt, &handle_ci)
        quit_evt = CML.wrap(quit_flg.i_get_evt) { quit.call; nil }

        CML.select([mouse_evt, child_evt, quit_evt])
      }

      # Track mouse function
      track_mouse = -> {
        # Create child command event
        cmd_wrap = ->(wenv : WSys::WinEnv, data : {name: String, frame: Frame::Frame?}) {
          CML.wrap(wenv.cmd_out.recv_evt) do |msg|
            {msg, wenv, data[:frame].not_nil!}
          end
        }

        child_cmd_evts = w_map.list_all.map { |(wenv, data)| cmd_wrap.call(wenv, data) }
        child_cmd_evt = CML.choose(child_cmd_evts)
        mouse_router.call(false, child_cmd_evt)
      }

      # Do menu function (simplified)
      do_menu = ->(pos : Geom::Point) {
        # Menu implementation omitted for brevity
        track_mouse.call
      }

      track_mouse.call
    }

    # Keyboard router
    kbd_router = -> {
      loop do
        msg = root_env.kbd.recv
        current = cur_frame.m_take
        if current
          Frame.frame_env(current).kbd.send(msg)
        end
        cur_frame.m_put(current)
      end
    }

    # Command-in router
    cmd_in_router = -> {
      loop do
        msg = root_env.cmd_in.recv
        if msg.msg == "Delete"
          quit_flg.i_put(nil)
        end
      end
    }

    # Spawn all three threads
    CML.spawn(&controller)
    CML.spawn(&kbd_router)
    CML.spawn(&cmd_in_router)
  end

  # Utility functions
  def self.while_mouse_btn(m : CML::Chan(DpySystem::MouseMsg), b : Bool) : Geom::Point
    loop do
      msg = m.recv
      return msg.pos if msg.btn != b
    end
  end

  def self.pick_win(w_map : WinMap({name: String, frame: Frame::Frame?}), m : CML::Chan(DpySystem::MouseMsg)) : WSys::WinEnv?
    w1 = w_map.find_by_pt(while_mouse_btn(m, false)).first
    w2 = w_map.find_by_pt(while_mouse_btn(m, true)).first
    parent_env = w_map.parent.first
    if !w1.same?(parent_env) && w1.same?(w2)
      w1
    else
      nil
    end
  end

  def self.create_child(w_map : WinMap({name: String, frame: Frame::Frame?}), name : String, rect : Geom::Rect, realize : WSys::WinEnv -> Nil) : Frame::Frame
    parent_env = w_map.parent.first
    child, _ = WSys::WinEnv.realize(parent_env.bmap, rect) do |child_env|
      Frame.mk_frame(realize, child_env)
    end
    w_map.insert(Frame.frame_env(child), {name: name, frame: child})
    child
  end

  def self.delete_child(w_map : WinMap({name: String, frame: Frame::Frame?}), wenv : WSys::WinEnv)
    # Send delete request and wait for acknowledgment
    wenv.cmd_in.send(WSys::Cmd.new("Delete"))
    loop do
      ack = wenv.cmd_out.recv
      break if ack.msg == "Delete"
    end
    w_map.delete(wenv)
  end
end

# Mock implementations for testing
module Mock
  class MockBitmap < DpySystem::Bitmap
    getter rect : Geom::Rect

    def initialize(@rect : Geom::Rect)
      puts "MockBitmap.new(#{rect})"
    end

    def draw_line(rop : DpySystem::RasterOp, pt1 : Geom::Point, pt2 : Geom::Point) : Nil
      puts "draw_line(#{rop}, #{pt1}, #{pt2})"
    end

    def draw_rect(rop : DpySystem::RasterOp, rect : Geom::Rect) : Nil
      puts "draw_rect(#{rop}, #{rect})"
    end

    def fill_rect(rop : DpySystem::RasterOp, texture : DpySystem::Texture, rect : Geom::Rect) : Nil
      puts "fill_rect(#{rop}, #{texture}, #{rect})"
    end

    def bitblt(dst : DpySystem::Bitmap, rop : DpySystem::RasterOp, pt : Geom::Point, src : DpySystem::Bitmap, src_rect : Geom::Rect) : Nil
      puts "bitblt(dst, #{rop}, #{pt}, src, #{src_rect})"
    end

    def draw_text(rop : DpySystem::RasterOp, pt : Geom::Point, text : String) : Nil
      puts "draw_text(#{rop}, #{pt}, #{text.inspect})"
    end

    def string_size(text : String) : {wid: Int32, ht: Int32, ascent: Int32}
      {wid: text.size * 8, ht: 16, ascent: 12}
    end

    def mk_bitmap(rect : Geom::Rect) : DpySystem::Bitmap
      MockBitmap.new(rect)
    end

    def to_front : Nil
      puts "to_front"
    end

    def to_back : Nil
      puts "to_back"
    end

    def move(pt : Geom::Point) : Nil
      puts "move(#{pt})"
      @rect = Geom::Rect.new(pt.x, pt.y, @rect.wid, @rect.ht)
    end

    def delete : Nil
      puts "delete"
    end

    def same?(other : DpySystem::Bitmap) : Bool
      self.object_id == other.object_id
    end

    def bitmap_rect : Geom::Rect
      @rect
    end

    def clr : Nil
      puts "clr"
    end
  end

  # Mock WinMap implementation
  class MockWinMap(T) < WinMap(T)
    @root_env : WSys::WinEnv
    @root_data : T
    @windows : Array({WSys::WinEnv, T})

    def initialize(@root_env : WSys::WinEnv, @root_data : T)
      @windows = [] of {WSys::WinEnv, T}
    end

    def self.mk_win_map(root_env : WSys::WinEnv, data : T) : WinMap(T)
      MockWinMap(T).new(root_env, data)
    end

    def parent : {WSys::WinEnv, T}
      {@root_env, @root_data}
    end

    def insert(wenv : WSys::WinEnv, data : T) : Nil
      @windows << {wenv, data}
    end

    def delete(wenv : WSys::WinEnv) : Nil
      @windows.reject! { |(env, _)| env.same?(wenv) }
    end

    def list_all : Array({WSys::WinEnv, T})
      @windows.dup
    end

    def to_front(wenv : WSys::WinEnv) : Nil
      # Simplified: move to end of list
      if idx = @windows.index { |(env, _)| env.same?(wenv) }
        entry = @windows.delete_at(idx)
        @windows << entry
      end
    end

    def to_back(wenv : WSys::WinEnv) : Nil
      # Simplified: move to beginning of list
      if idx = @windows.index { |(env, _)| env.same?(wenv) }
        entry = @windows.delete_at(idx)
        @windows.unshift(entry)
      end
    end

    def move(wenv : WSys::WinEnv, pt : Geom::Point) : Nil
      # In a real implementation, would update window position
      puts "move window #{wenv} to #{pt}"
    end

    def map_mouse(msg : DpySystem::MouseMsg) : {DpySystem::MouseMsg, WSys::WinEnv, T}
      # Simplified: always map to root window
      {msg, @root_env, @root_data}
    end

    def find_by_pt(pt : Geom::Point) : {WSys::WinEnv, T}
      # Simplified: return root window
      {@root_env, @root_data}
    end

    def find_by_env(wenv : WSys::WinEnv) : T
      # Find data for window
      @windows.each do |env, data|
        return data if env.same?(wenv)
      end
      @root_data
    end
  end

  # Mock display function
  def self.display(name : String?) : {dpy: DpySystem::Bitmap, mouse: CML::Event(DpySystem::MouseMsg), kbd: CML::Event(DpySystem::KeyPress)}
    bitmap = MockBitmap.new(Geom::Rect.new(x: 0, y: 0, wid: 1024, ht: 768))
    mouse_chan = CML::Chan(DpySystem::MouseMsg).new
    kbd_chan = CML::Chan(DpySystem::KeyPress).new

    {
      dpy:   bitmap,
      mouse: mouse_chan.recv_evt,
      kbd:   kbd_chan.recv_evt,
    }
  end
end

# Override WinMap.mk_win_map to use mock implementation
class WinMap(T)
  def self.mk_win_map(root_env : WSys::WinEnv, data : T) : WinMap(T)
    Mock::MockWinMap(T).new(root_env, data)
  end
end

# Example usage
if PROGRAM_NAME.includes?("display.cr")
  puts "=== Crystal CML Window System Demo ==="

  # Create root environment using mock display
  dpy_info = Mock.display(nil)
  root_env = WSys::WinEnv.mk_env(dpy_info[:dpy])

  # Define a simple client
  client = ->(env : WSys::WinEnv) {
    # Create a button in this window
    button_env = Button.mk_button("Click me", -> { puts "Button clicked!" }, env)
    # The button runs its own event loop in a fiber
    nil
  }

  clients = [
    {name: "Window 1", size: Geom::Rect.new(x: 50, y: 50, wid: 200, ht: 100), realize: client},
    {name: "Window 2", size: Geom::Rect.new(x: 100, y: 100, wid: 200, ht: 100), realize: client},
  ]

  puts "Starting window manager with #{clients.size} clients..."

  # Start window manager (spawns fibers)
  WinManager.win_manager(root_env, clients)

  # Run for a short time to demonstrate
  puts "Running for 2 seconds..."
  sleep 2.seconds
  puts "Demo complete."

  # Send quit signal
  root_env.cmd_in.send(WSys::Cmd.new("Delete"))
  sleep 0.1.seconds
end