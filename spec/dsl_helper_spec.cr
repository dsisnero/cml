require "./spec_helper"

describe "CML DSL helpers" do
  it "after delays execution until timeout" do
    start = SpecTime.monotonic
    result = CML.sync(CML.after(15.milliseconds) { :done })
    (SpecTime.monotonic - start).should be >= 10.milliseconds
    result.should eq(:done)
  end

  it "spawn_evt spawns on sync" do
    flag = Atomic(Bool).new(false)

    tid = CML.sync(CML.spawn_evt { flag.set(true) })

    tid.should be_a(CML::Thread::Id)
    # give fiber a moment to run
    sleep 10.milliseconds
    flag.get.should be_true
  end
end
