require "./spec_helper"

module CML
  describe Cleanup do
    describe "log/unlog channel" do
      it "logs a channel and unlogs it" do
        ch = Chan(Int32).new
        Cleanup.log_channel("test_ch", ch)
        Cleanup.unlog_channel("test_ch").should be_true
        Cleanup.unlog_channel("test_ch").should be_false
      end

      it "logs multiple channels" do
        ch1 = Chan(Int32).new
        ch2 = Chan(String).new
        Cleanup.log_channel("ch1", ch1)
        Cleanup.log_channel("ch2", ch2)
        Cleanup.unlog_channel("ch1").should be_true
        Cleanup.unlog_channel("ch2").should be_true
      end

      it "overwrites previous log with same name" do
        ch1 = Chan(Int32).new
        ch2 = Chan(String).new
        Cleanup.log_channel("dup", ch1)
        Cleanup.log_channel("dup", ch2)
        # should have only ch2 logged
        Cleanup.unlog_channel("dup").should be_true
        Cleanup.unlog_channel("dup").should be_false
      end
    end

    describe "log/unlog mailbox" do
      it "logs a mailbox and unlogs it" do
        mb = Mailbox(Int32).new
        Cleanup.log_mailbox("test_mb", mb)
        Cleanup.unlog_mailbox("test_mb").should be_true
        Cleanup.unlog_mailbox("test_mb").should be_false
      end
    end

    describe "log/unlog server" do
      it "logs a server with init and shut procs" do
        init_called = false
        shut_called = false
        Cleanup.log_server("srv", -> { init_called = true; nil }, -> { shut_called = true; nil })
        # init not called yet
        init_called.should be_false
        # trigger clean with AtInit (should call init)
        Cleanup.clean_all(Cleanup::When::AtInit)
        init_called.should be_true
        shut_called.should be_false
        # trigger clean with AtExit (should call shut)
        Cleanup.clean_all(Cleanup::When::AtExit)
        shut_called.should be_true
      end
    end

    describe "clean channels" do
      it "resets logged channels on clean" do
        ch = Chan(Int32).new
        Cleanup.log_channel("ch", ch)
        # clean channels via AtInit (calls reset) - should not raise
        Cleanup.clean_all(Cleanup::When::AtInit)
        # channel still works (no pending operations)
        ch.send_poll(42).should be_false # no receiver
        ch.recv_poll.should be_nil       # no sender
      end
    end

    describe "clean servers" do
      it "calls init on AtInit and shut on AtExit" do
        init_called = 0
        shut_called = 0
        Cleanup.log_server("srv", -> { init_called += 1; nil }, -> { shut_called += 1; nil })
        Cleanup.clean_all(Cleanup::When::AtInit)
        init_called.should eq(1)
        shut_called.should eq(0)
        Cleanup.clean_all(Cleanup::When::AtExit)
        init_called.should eq(1)
        shut_called.should eq(1)
      end
    end

    describe "standard cleaners" do
      it "registers standard cleaners automatically" do
        # just ensure no error
        Cleanup.register_standard_cleaners
      end
    end

    describe "unlog_all" do
      it "clears all logged items" do
        ch = Chan(Int32).new
        mb = Mailbox(Int32).new
        Cleanup.log_channel("ch", ch)
        Cleanup.log_mailbox("mb", mb)
        Cleanup.log_server("srv", -> { }, -> { })
        Cleanup.unlog_all
        Cleanup.unlog_channel("ch").should be_false
        Cleanup.unlog_mailbox("mb").should be_false
        Cleanup.unlog_server("srv").should be_false
      end
    end
  end
end
