require "./spec_helper"
require "../src/cml"
require "../src/cml/trace_cml"

describe CML::TraceCML do
  describe "TraceModule" do
    it "has a root trace module" do
      root = CML::TraceCML.trace_root
      root.should_not be_nil
      root.full_name.should eq("/")
    end

    it "creates child trace modules" do
      root = CML::TraceCML.trace_root
      child = CML::TraceCML.trace_module(root, "test_child")
      child.full_name.should eq("/test_child")
      child.label.should eq("test_child")
    end

    it "creates nested trace modules" do
      root = CML::TraceCML.trace_root
      parent = CML::TraceCML.trace_module(root, "parent")
      child = CML::TraceCML.trace_module(parent, "child")
      child.full_name.should eq("/parent/child")
    end

    it "returns existing child if already created" do
      root = CML::TraceCML.trace_root
      child1 = CML::TraceCML.trace_module(root, "duplicate_test")
      child2 = CML::TraceCML.trace_module(root, "duplicate_test")
      child1.should be(child2)
    end
  end

  describe "tracing control" do
    it "starts with tracing off" do
      root = CML::TraceCML.trace_root
      tm = CML::TraceCML.trace_module(root, "trace_test1")
      CML::TraceCML.am_tracing(tm).should be_false
    end

    it "turns tracing on" do
      root = CML::TraceCML.trace_root
      tm = CML::TraceCML.trace_module(root, "trace_test2")
      CML::TraceCML.trace_on(tm)
      CML::TraceCML.am_tracing(tm).should be_true
    end

    it "turns tracing off" do
      root = CML::TraceCML.trace_root
      tm = CML::TraceCML.trace_module(root, "trace_test3")
      CML::TraceCML.trace_on(tm)
      CML::TraceCML.trace_off(tm)
      CML::TraceCML.am_tracing(tm).should be_false
    end

    it "trace_on affects children" do
      root = CML::TraceCML.trace_root
      parent = CML::TraceCML.trace_module(root, "trace_parent")
      child = CML::TraceCML.trace_module(parent, "trace_child")

      CML::TraceCML.trace_on(parent)

      CML::TraceCML.am_tracing(parent).should be_true
      CML::TraceCML.am_tracing(child).should be_true
    end

    it "trace_only affects only the module itself" do
      root = CML::TraceCML.trace_root
      parent = CML::TraceCML.trace_module(root, "trace_only_parent")
      child = CML::TraceCML.trace_module(parent, "trace_only_child")

      CML::TraceCML.trace_only(parent)

      CML::TraceCML.am_tracing(parent).should be_true
      CML::TraceCML.am_tracing(child).should be_false
    end
  end

  describe "module lookup" do
    it "finds modules by path" do
      root = CML::TraceCML.trace_root
      tm = CML::TraceCML.trace_module(root, "findable")
      found = CML::TraceCML.module_of("/findable")
      found.should eq(tm)
    end

    it "raises for non-existent modules" do
      expect_raises(CML::TraceCML::NoSuchModule) do
        CML::TraceCML.module_of("/does_not_exist_xyz")
      end
    end

    it "returns nil for non-existent modules with module_of?" do
      result = CML::TraceCML.module_of?("/does_not_exist_abc")
      result.should be_nil
    end
  end

  describe "name_of" do
    it "returns the full name of a module" do
      root = CML::TraceCML.trace_root
      tm = CML::TraceCML.trace_module(root, "named_module")
      CML::TraceCML.name_of(tm).should eq("/named_module")
    end
  end

  describe "status" do
    it "returns status of module tree" do
      root = CML::TraceCML.trace_root
      parent = CML::TraceCML.trace_module(root, "status_parent")
      child = CML::TraceCML.trace_module(parent, "status_child")

      CML::TraceCML.trace_on(parent)

      status = CML::TraceCML.status(parent)
      status.size.should eq(2)
      status[0][1].should be_true # parent is traced
      status[1][1].should be_true # child is traced
    end
  end

  describe "trace output" do
    it "can set trace destination to null" do
      CML::TraceCML.set_trace_file(CML::TraceCML::TraceTo::Null)
      # Should not raise
    end

    it "can set trace destination to stdout" do
      CML::TraceCML.set_trace_file(CML::TraceCML::TraceTo::Out)
      # Should not raise
    end

    it "can set trace destination to stderr" do
      CML::TraceCML.set_trace_file(CML::TraceCML::TraceTo::Err)
      # Should not raise
    end

    it "can set trace to a stream" do
      io = IO::Memory.new
      CML::TraceCML.set_trace_stream(io)
      # Should not raise
    end

    it "writes trace output when enabled" do
      io = IO::Memory.new
      CML::TraceCML.set_trace_stream(io)

      root = CML::TraceCML.trace_root
      tm = CML::TraceCML.trace_module(root, "output_test")
      CML::TraceCML.trace_on(tm)

      CML::TraceCML.trace(tm, "test message")

      io.to_s.should contain("test message")
    end

    it "does not write trace output when disabled" do
      io = IO::Memory.new
      CML::TraceCML.set_trace_stream(io)

      root = CML::TraceCML.trace_root
      tm = CML::TraceCML.trace_module(root, "silent_test")
      CML::TraceCML.trace_off(tm)

      CML::TraceCML.trace(tm, "should not appear")

      io.to_s.should eq("")
    end

    it "writes trace output with block" do
      io = IO::Memory.new
      CML::TraceCML.set_trace_stream(io)

      root = CML::TraceCML.trace_root
      tm = CML::TraceCML.trace_module(root, "block_test")
      CML::TraceCML.trace_on(tm)

      CML::TraceCML.trace(tm) { ["hello", " ", "world"] }

      io.to_s.should contain("hello world")
    end
  end

  describe "exception handling" do
    it "can set and reset uncaught exception handler" do
      called = false
      handler = ->(_fiber : Fiber, _ex : Exception) { called = true; nil }

      CML::TraceCML.set_uncaught_fn(handler)
      CML::TraceCML.reset_uncaught_fn
      # Should not raise
    end

    it "can add exception filters" do
      filter = ->(_fiber : Fiber, _ex : Exception) { false }
      CML::TraceCML.set_handle_fn(filter)
      # Should not raise
    end
  end

  describe "spawn_traced" do
    it "spawns a fiber with exception handling" do
      done = Channel(Nil).new(1)

      fiber = CML::TraceCML.spawn_traced("test_fiber") do
        done.send(nil)
      end

      done.receive
      fiber.should_not be_nil
    end
  end
end