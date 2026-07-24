require "./spec_helper"

describe "CML Running Flag" do
  it "reports the runtime enabled by default" do
    CML.running?.should be_true
  end

  it "allows explicit run scopes while the runtime is enabled by default" do
    ran = false
    CML.run do
      CML.running?.should be_true
      ran = true
    end
    ran.should be_true
  end

  it "raises if run is nested inside an active run scope" do
    CML.run do
      expect_raises(Exception, "CML is already running") do
        CML.run { }
      end
    end
  end

  it "raises if shutdown when not running" do
    CML.set_running(false)
    begin
      expect_raises(Exception, "CML is not running") do
        CML.shutdown
      end
    ensure
      CML.set_running(true)
    end
  end

  it "prevents sync when not running" do
    CML.set_running(false)
    begin
      chan = CML.channel(Int32)
      expect_raises(Exception, "CML is not running") do
        CML.sync(chan.recv_evt)
      end
    ensure
      CML.set_running(true)
    end
  end

  it "cleanup operations still work when the runtime is disabled" do
    CML.set_running(false)
    begin
      CML::Cleanup.log_channel("test", CML.channel(Int32))
      CML::Cleanup.unlog_channel("test").should be_true
    ensure
      CML.set_running(true)
    end
  end

  it "cleanup AtInit and AtShutdown called during run" do
    begin
      CML.run do
        chan = CML.channel(Int32)
        CML::Cleanup.log_channel("test2", chan)
      end
    ensure
      CML::Cleanup.unlog_channel("test2") rescue nil
    end
  end
end
