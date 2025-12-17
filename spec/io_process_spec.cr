require "./spec_helper"

describe "CML IO helpers" do
  it "reads bytes via read_evt when data arrives" do
    reader, writer = IO.pipe

    begin
      ::spawn do
        sleep 20.milliseconds
        writer << "hello"
        writer.flush
        writer.close
      end

      bytes = CML.sync(CML.read_evt(reader, 5))
      String.new(bytes).should eq("hello")
    ensure
      reader.close unless reader.closed?
      writer.close unless writer.closed?
    end
  end

  it "reads lines via read_line_evt" do
    reader, writer = IO.pipe

    begin
      ::spawn do
        sleep 10.milliseconds
        writer.puts "line"
        writer.flush
        writer.close
      end

      line = CML.sync(CML.read_line_evt(reader))
      line.should eq("line\n")
    ensure
      reader.close unless reader.closed?
      writer.close unless writer.closed?
    end
  end

  it "reads all contents via read_all_evt" do
    reader, writer = IO.pipe

    begin
      ::spawn do
        writer << "abc"
        writer << "def"
        writer.close
      end

      result = CML.sync(CML.read_all_evt(reader))
      result.should eq("abcdef")
    ensure
      reader.close unless reader.closed?
      writer.close unless writer.closed?
    end
  end

  it "cancels a pending read when another branch wins" do
    reader, writer = IO.pipe

    begin
      result = CML.sync(CML.choose([
        CML.wrap(CML.read_evt(reader, 5)) { "read" },
        CML.wrap(CML.timeout(30.milliseconds)) { "timeout" },
      ]))

      result.should eq("timeout")
    ensure
      reader.close unless reader.closed?
      writer.close unless writer.closed?
    end
  end
end

describe "CML process helpers" do
  it "runs a system command via an event" do
    status = CML.sync(CML::Process.system_evt("echo cml"))
    status.success?.should be_true
  end

  it "provides a synchronous system helper" do
    status = CML::Process.system("echo quick")
    status.success?.should be_true
  end

  it "can race a system command with a timeout" do
    result = CML.sync(CML.choose([
      CML.wrap(CML::Process.system_evt("sleep 0.3")) { "done" },
      CML.wrap(CML.timeout(30.milliseconds)) { "timeout" },
    ]))

    result.should eq("timeout")
  end
end
