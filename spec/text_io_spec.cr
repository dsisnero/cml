require "./spec_helper"

describe "CML::TextIO" do
  it "reads from open_string" do
    instream = CML::TextIO.open_string("hello")
    ch, _ = CML::TextIO.input1(instream).not_nil!
    ch.should eq('h')

    str, _ = CML::TextIO.input_n(instream, 2)
    str.should eq("el")

    rest, _ = CML::TextIO.input_all(instream)
    rest.should eq("lo")
  end

  it "supports lookahead without consuming" do
    instream = CML::TextIO.open_string("ab")
    peek = CML::TextIO.lookahead(instream)
    peek.should eq('a')

    ch, _ = CML::TextIO.input1(instream).not_nil!
    ch.should eq('a')
  end

  it "reads lines with input_line" do
    instream = CML::TextIO.open_string("line1\nline2\n")
    line1, _ = CML::TextIO.input_line(instream).not_nil!
    line1.should eq("line1\n")
    line2, _ = CML::TextIO.input_line(instream).not_nil!
    line2.should eq("line2\n")
  end

  it "writes output and output_substr" do
    path = File.tempname("cml_text_io")
    outstream = CML::TextIO.open_out(path)
    begin
      outstream = CML::TextIO.output(outstream, "hello")
      outstream = CML::TextIO.output1(outstream, '!')
      outstream = CML::TextIO.output_substr(outstream, "world", 0, 3)
      CML::TextIO.flush_out(outstream)
    ensure
      CML::TextIO.close_out(outstream)
    end

    content = File.read(path)
    content.should eq("hello!wor")
  ensure
    File.delete?(path.not_nil!)
  end

  it "supports channel-based streams" do
    chan = CML::Chan(String?).new
    instream = CML::TextIO.open_chan_in(chan)
    outstream = CML::TextIO.open_chan_out(chan)

    spawn do
      CML::TextIO.output(outstream, "ping")
      CML::TextIO.close_out(outstream)
    end

    data, _ = CML::TextIO.input_all(instream)
    data.should eq("ping")
  end

  it "provides event-valued input ops" do
    instream = CML::TextIO.open_string("abc")

    result = CML.sync(CML::TextIO.input1_evt(instream))
    result.should_not be_nil
    ch, _ = result.not_nil!
    ch.should eq('a')
  end
end
