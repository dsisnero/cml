require "./spec_helper"

describe "CML stream-like IO helpers" do
  it "input_evt reads bytes" do
    reader, writer = IO.pipe

    ::spawn do
      writer << "abc"
      writer.flush
      writer.close
    end

    bytes = CML.sync(CML.input_evt(reader, 3))
    String.new(bytes).should eq("abc")
  ensure
    reader.try &.close
    writer.try &.close
  end

  it "input_line_evt reads a line" do
    reader, writer = IO.pipe

    ::spawn do
      writer.puts "line"
      writer.close
    end

    line = CML.sync(CML.input_line_evt(reader))
    line.should eq("line\n")
  ensure
    reader.try &.close
    writer.try &.close
  end

  it "write_evt writes to an IO" do
    reader, writer = IO.pipe

    ::spawn do
      CML.sync(CML.write_evt(writer, "hello".to_slice))
      writer.close
    end

    bytes = reader.read_string(5)
    bytes.should eq("hello")
  ensure
    reader.try &.close
    writer.try &.close
  end
end
