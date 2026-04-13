require "./spec_helper"

private def wait_process_with_timeout(process : Process, timeout = 60.seconds) : Process::Status?
  ch = Channel(Process::Status).new(1)
  spawn do
    ch.send(process.wait)
  end

  select
  when status = ch.receive
    status
  when timeout(timeout)
    nil
  end
end

private def append_node_logs(output : String) : String
  combined = output
  ["examples/tuple/node0.log", "examples/tuple/node1.log", "examples/tuple/node2.log"].each do |path|
    next unless File.exists?(path)
    combined += "\n---- #{path} ----\n"
    combined += File.read(path)
  end
  combined
end

describe "Distributed dining hang regression" do
  it "completes without hanging on 3 nodes" do
    base_port = 20_000 + Random.rand(20_000)
    port0 = base_port
    port1 = base_port + 1
    port2 = base_port + 2

    stdout_buf = IO::Memory.new
    stderr_buf = IO::Memory.new

    process = Process.new(
      "make",
      [
        "-C", "examples/tuple", "dining-distributed",
        "NODES=3",
        "ROUNDS=2",
        "LINGER=1.0",
        "PORT0=#{port0}",
        "PORT1=#{port1}",
        "PORT2=#{port2}",
      ],
      output: stdout_buf,
      error: stderr_buf
    )

    status = wait_process_with_timeout(process, timeout: 60.seconds)
    if status.nil?
      process.terminate rescue nil
      sleep 200.milliseconds
      process.signal(Signal::KILL) rescue nil

      combined = append_node_logs(stdout_buf.to_s + stderr_buf.to_s)
      if combined.includes?("Operation not permitted")
        pending!("network bind/connect not permitted in this environment")
      end

      fail "distributed dining hung for >60s\nstdout:\n#{stdout_buf.to_s}\nstderr:\n#{stderr_buf.to_s}\nlogs:\n#{combined}"
    end

    combined = stdout_buf.to_s + stderr_buf.to_s
    if !status.success?
      combined = append_node_logs(combined)
    end

    if combined.includes?("Operation not permitted")
      pending!("network bind/connect not permitted in this environment")
    end

    status.success?.should be_true
    combined.should contain("node=0 done")
    combined.should contain("node=1 done")
    combined.should contain("node=2 done")
  end
end
