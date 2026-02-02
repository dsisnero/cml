require "./spec_helper"

describe "CML Running Flag" do
  it "reports running by default" do
    CML.running?.should be_true
  end

  it "allows run/shutdown cycle" do
    ran = false
    CML.set_running(false)
    begin
      CML.run do
        CML.running?.should be_true
        ran = true
      end
      ran.should be_true
    ensure
      CML.set_running(true) # restore default
    end
  end

  it "raises if run when already running" do
    # Temporarily set flag false to test run
    CML.set_running(false)
    begin
      CML.run do
        # nested run should raise
        expect_raises(Exception, "CML is already running") do
          CML.run { }
        end
      end
    ensure
      CML.set_running(true) # restore
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

  it "cleanup protect works without lock when not running" do
    # This test verifies that Cleanup.protect skips mutex when CML not running
    # We can't directly test mutex behavior, but we can verify operations work
    CML.set_running(false)
    begin
      # Should not raise
      CML::Cleanup.log_channel("test", CML.channel(Int32))
      CML::Cleanup.unlog_channel("test").should be_true
    ensure
      CML.set_running(true)
    end
  end

  it "cleanup AtInit and AtShutdown called during run" do
    # We'll test by logging a channel and verifying reset is called
    # This is more complex; for now just ensure no exception
    CML.set_running(false)
    begin
      CML.run do
        # Should not raise
        chan = CML.channel(Int32)
        CML::Cleanup.log_channel("test2", chan)
      end
    ensure
      CML.set_running(true)
      CML::Cleanup.unlog_channel("test2") rescue nil
    end
  end
end
