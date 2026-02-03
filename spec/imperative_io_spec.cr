require "./spec_helper"

describe "CML::ImperativeIO" do
  it "wraps text streams with positions and lookahead" do
    io = IO::Memory.new("hello")
    stream = CML::StreamIO.open_text_in(io)
    instream = CML::ImperativeIO.mk_instream(stream)

    instream.get_pos_in.should eq(0)
    instream.lookahead.should eq('h')
    instream.get_pos_in.should eq(0)

    result = instream.input1
    result.should_not be_nil
    result.not_nil![0].should eq('h')
    instream.get_pos_in.should eq(1)

    chunk, _ = instream.input_n(2)
    chunk.should eq("el")
    instream.get_pos_in.should eq(3)

    rest, _ = instream.input_all
    rest.should eq("lo")
    instream.get_pos_in.should eq(5)
    instream.end_of_stream.should be_true
  end

  it "wraps text output streams with position tracking" do
    io = IO::Memory.new
    stream = CML::StreamIO.open_text_out(io)
    outstream = CML::ImperativeIO.mk_outstream(stream)

    outstream.output("hi")
    outstream.output1('!')
    outstream.flush_out

    io.to_s.should eq("hi!")
    outstream.get_pos_out.should eq(3)
  end

  it "wraps binary streams with positions" do
    io = IO::Memory.new(Bytes[1, 2, 3])
    stream = CML::StreamIO.open_bin_in(io)
    instream = CML::ImperativeIO.mk_instream(stream)

    result = instream.input1
    result.should_not be_nil
    result.not_nil![0].should eq(1_u8)
    instream.get_pos_in.should eq(1)

    chunk, _ = instream.input_n(2)
    chunk.should eq(Bytes[2, 3])
    instream.get_pos_in.should eq(3)
    instream.end_of_stream.should be_true
  end

  it "wraps binary output streams with position tracking" do
    io = IO::Memory.new
    stream = CML::StreamIO.open_bin_out(io)
    outstream = CML::ImperativeIO.mk_outstream(stream)

    outstream.output(Bytes[4, 5])
    outstream.output1(6_u8)
    outstream.flush_out

    io.to_slice.should eq(Bytes[4, 5, 6])
    outstream.get_pos_out.should eq(3)
  end
end
