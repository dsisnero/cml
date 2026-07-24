require "./spec_helper"

describe "Kill-safe abstractions" do
  it "kills a thread waiting on a channel send" do
    CML.set_running(false)
    begin
      CML.run do
        ch = CML.channel(String)
        tid = CML.spawn do
          begin
            ch.send "hello"
          rescue CML::Thread::Killed
            # expected
          end
        end
        # Give thread a chance to block on send
        CML.sleep(10.milliseconds)
        CML.kill(tid)
        # Channel should still be usable; no sender remains, so timeout should win.
        select_result = CML.select(ch.recv_evt, CML.timeout(50.milliseconds))
        select_result.should be_a(String | Nil)
        select_result.should be_nil
      end
    ensure
      CML.set_running(true)
    end
  end

  it "kills a thread waiting on a channel receive" do
    CML.set_running(false)
    begin
      CML.run do
        ch = CML.channel(Int32)
        tid = CML.spawn do
          begin
            ch.recv
          rescue CML::Thread::Killed
          end
        end
        CML.sleep(10.milliseconds)
        CML.kill(tid)
        # Channel should still be usable
        CML.spawn do
          ch.send 42
        end
        value = CML.select(ch.recv_evt, CML.timeout(50.milliseconds))
        value.should eq(42)
      end
    ensure
      CML.set_running(true)
    end
  end

  it "killed thread raises Thread::Killed on next sync" do
    CML.set_running(false)
    begin
      CML.run do
        ch = CML.channel(Int32)
        got_killed = false

        tid = CML.spawn do
          begin
            CML.sync(ch.recv_evt)
          rescue CML::Thread::Killed
            got_killed = true
          end
        end

        # Let the spawned fiber block on recv
        CML.sleep(10.milliseconds)
        CML.kill(tid)
        # Give the killed fiber time to wake up and process the exception
        CML.sleep(20.milliseconds)

        got_killed.should be_true
      end
    ensure
      CML.set_running(true)
    end
  end

  it "kill removes thread from channel waiting queue" do
    CML.set_running(false)
    begin
      CML.run do
        ch = CML.channel(Int32)
        tid = CML.spawn do
          begin
            ch.send 99
          rescue CML::Thread::Killed
            # expected
          end
        end
        CML.sleep(10.milliseconds)
        # Check that send is pending (queue size? not exposed)
        # Kill the thread
        CML.kill(tid)
        # Now send from another thread and receive from main fiber.
        CML.spawn do
          ch.send 100
        end
        # Receiver should get 100
        value = CML.select(ch.recv_evt, CML.timeout(50.milliseconds))
        value.should eq(100)
      end
    ensure
      CML.set_running(true)
    end
  end
end
