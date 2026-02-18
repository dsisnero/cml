require "./spec_helper"

describe "Custodian kill-safe parity" do
  it "does not resume with thread_resume(t) when all controllers are shut down" do
    CML.set_running(false)
    begin
      CML.run do
        cust = CML.make_custodian
        ticks = Atomic(Int32).new(0)
        stop = Atomic(Bool).new(false)

        tid = CML.with_custodian(cust) do
          CML.spawn do
            until stop.get
              ticks.add(1)
              CML.sleep(2.milliseconds)
            end
          rescue CML::Thread::Killed
          end
        end

        CML.sleep(15.milliseconds)
        before_shutdown = ticks.get
        CML.custodian_shutdown_all(cust)
        CML.sleep(20.milliseconds)
        after_shutdown = ticks.get
        after_shutdown.should eq(before_shutdown)

        CML.thread_resume(tid)
        CML.sleep(20.milliseconds)
        ticks.get.should eq(after_shutdown)

        cust2 = CML.make_custodian
        CML.thread_resume(tid, cust2)
        CML.sleep(20.milliseconds)
        ticks.get.should be > after_shutdown

        stop.set(true)
        CML.kill(tid)
      end
    ensure
      CML.set_running(true)
    end
  end

  it "yokes controller and resume behavior with thread_resume(t, source_thread)" do
    CML.set_running(false)
    begin
      CML.run do
        cust1 = CML.make_custodian
        cust2 = CML.make_custodian
        ticks1 = Atomic(Int32).new(0)
        ticks2 = Atomic(Int32).new(0)
        stop1 = Atomic(Bool).new(false)
        stop2 = Atomic(Bool).new(false)

        t1 = CML.with_custodian(cust1) do
          CML.spawn do
            until stop1.get
              ticks1.add(1)
              CML.sleep(2.milliseconds)
            end
          rescue CML::Thread::Killed
          end
        end

        t2 = CML.with_custodian(cust2) do
          CML.spawn do
            until stop2.get
              ticks2.add(1)
              CML.sleep(2.milliseconds)
            end
          rescue CML::Thread::Killed
          end
        end

        CML.sleep(15.milliseconds)
        CML.custodian_shutdown_all(cust1)
        paused_t1 = ticks1.get
        CML.sleep(20.milliseconds)
        ticks1.get.should eq(paused_t1)
        ticks2.get.should be > 0

        CML.thread_resume(t1, t2)
        CML.sleep(20.milliseconds)
        resumed_t1 = ticks1.get
        resumed_t1.should be > paused_t1

        CML.custodian_shutdown_all(cust2)
        paused_again = ticks1.get
        CML.sleep(20.milliseconds)
        ticks1.get.should eq(paused_again)

        cust3 = CML.make_custodian
        CML.thread_resume(t2, cust3)
        CML.sleep(20.milliseconds)
        ticks1.get.should be > paused_again

        stop1.set(true)
        stop2.set(true)
        CML.kill(t1)
        CML.kill(t2)
      end
    ensure
      CML.set_running(true)
    end
  end
end
