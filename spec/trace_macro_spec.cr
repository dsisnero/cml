require "./spec_helper"

describe "CML::Tracer" do
  it "compiles without -Dtrace flag" do
    # Should compile and run without errors
    CML.trace "test", "data"
    CML::Tracer.set_output(STDOUT)
    CML::Tracer.set_filter_tags(["test"])
    CML::Tracer.set_fiber_name("test_fiber")
  end

  {% if flag?(:trace) %}
    it "emits trace output when enabled" do
      io = IO::Memory.new
      CML::Tracer.set_output(io)
      CML::Tracer.set_filter_tags(["spec"])

      CML.trace "spec_event", "payload", tag: "spec"

      output = io.to_s
      output.should contain("spec_event")
      output.should contain("payload")
    end
  {% else %}
    it "runs trace specs with -Dtrace (usage example)" do
      args = ["spec", "-Dtrace", "spec/trace_macro_spec.cr"]
      output = IO::Memory.new
      error = IO::Memory.new
      status = Process.run("crystal", args, output: output, error: error)
      status.success?.should be_true, "trace specs failed:\n#{error.to_s}\n#{output.to_s}"
    end
  {% end %}

  it "has Tracer configuration API" do
    # Test that API methods exist (compile-time check)
    typeof(CML::Tracer.set_output(STDOUT))
    typeof(CML::Tracer.set_filter_tags(["tag1", "tag2"]))
    typeof(CML::Tracer.set_filter_events(["event1", "event2"]))
    typeof(CML::Tracer.set_filter_fibers(["fiber1"]))
    typeof(CML::Tracer.set_fiber_name("my_fiber"))
  end

  it "has trace macro with correct signature" do
    # Test macro signatures compile
    typeof(CML.trace("event"))
    typeof(CML.trace("event", "arg1"))
    typeof(CML.trace("event", "arg1", 42))
    typeof(CML.trace("event", "arg1", tag: "mytag"))
    typeof(CML.trace("event", tag: "mytag"))
  end
end
