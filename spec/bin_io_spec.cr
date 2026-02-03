require "./spec_helper"

describe "CML::BinIO" do
  it "reads from open_string" do
    instream = CML::BinIO.open_string(Bytes[1, 2, 3, 4])
    first = CML::BinIO.input1(instream)
    first.should_not be_nil
    byte, _ = first.not_nil!
    byte.should eq(1_u8)

    chunk, _ = CML::BinIO.input_n(instream, 2)
    chunk.should eq(Bytes[2, 3])

    rest, _ = CML::BinIO.input_all(instream)
    rest.should eq(Bytes[4])
  end

  it "writes output and output_substr" do
    path = File.tempname("cml_bin_io")
    outstream = CML::BinIO.open_out(path)
    begin
      outstream = CML::BinIO.output(outstream, Bytes[9, 8, 7])
      outstream = CML::BinIO.output1(outstream, 6_u8)
      outstream = CML::BinIO.output_substr(outstream, Bytes[5, 4, 3, 2], 1, 2)
      CML::BinIO.flush_out(outstream)
    ensure
      CML::BinIO.close_out(outstream)
    end

    File.read(path).to_slice.should eq(Bytes[9, 8, 7, 6, 4, 3])
  ensure
    File.delete?(path.not_nil!)
  end

  it "supports channel-based streams" do
    chan = CML::Chan(Bytes?).new
    instream = CML::BinIO.open_chan_in(chan)
    outstream = CML::BinIO.open_chan_out(chan)

    spawn do
      CML::BinIO.output(outstream, Bytes[1, 2])
      CML::BinIO.close_out(outstream)
    end

    data, _ = CML::BinIO.input_all(instream)
    data.should eq(Bytes[1, 2])
  end

  it "provides event-valued input ops" do
    instream = CML::BinIO.open_string(Bytes[10, 11])
    result = CML.sync(CML::BinIO.input1_evt(instream))
    result.should_not be_nil
    byte, _ = result.not_nil!
    byte.should eq(10_u8)
  end
end
