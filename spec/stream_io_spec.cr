require "./spec_helper"

describe "CML::StreamIO" do
  it "input1_evt reads one character" do
    reader, writer = IO.pipe

    ::spawn do
      writer << "abc"
      writer.flush
      writer.close
    end

    instream = CML::StreamIO.open_text_in(reader)
    event = CML::StreamIO.input1_evt(instream)

    # First character
    result = CML.sync(event)
    result.should_not be_nil
    char, stream2 = result.as({Char, CML::StreamIO::Instream(Char)})
    char.should eq('a')

    # Second character (use new stream)
    event2 = CML::StreamIO.input1_evt(stream2)
    result2 = CML.sync(event2)
    result2.should_not be_nil
    char2, stream3 = result2.not_nil!
    char2.should eq('b')
  ensure
    reader.try &.close
    writer.try &.close
  end

  it "input1_evt returns nil on EOF" do
    reader, writer = IO.pipe

    ::spawn do
      writer.close
    end

    instream = CML::StreamIO.open_text_in(reader)
    event = CML::StreamIO.input1_evt(instream)

    result = CML.sync(event)
    result.should be_nil
  ensure
    reader.try &.close
    writer.try &.close
  end

  it "input_n_evt reads multiple characters" do
    reader, writer = IO.pipe

    ::spawn do
      writer << "hello"
      writer.flush
      writer.close
    end

    instream = CML::StreamIO.open_text_in(reader)
    event = CML::StreamIO.input_n_evt(instream, 3)

    str, stream2 = CML.sync(event)
    str.should eq("hel")

    # Read remaining
    event2 = CML::StreamIO.input_n_evt(stream2, 2)
    str2, stream3 = CML.sync(event2)
    str2.should eq("lo")
  ensure
    reader.try &.close
    writer.try &.close
  end

  it "input_evt reads available input" do
    reader, writer = IO.pipe

    writer << "test data"
    writer.flush

    instream = CML::StreamIO.open_text_in(reader)
    event = CML::StreamIO.input_evt(instream)

    str, stream2 = CML.sync(event)
    # Should read whatever is available (could be all or partial)
    str.should_not be_empty
    str.should contain("test")
  ensure
    reader.try &.close
    writer.try &.close
  end

  it "input_all_evt reads until EOF" do
    reader, writer = IO.pipe

    ::spawn do
      writer << "part1"
      writer << "part2"
      writer.flush
      writer.close
    end

    instream = CML::StreamIO.open_text_in(reader)
    event = CML::StreamIO.input_all_evt(instream)

    str, stream2 = CML.sync(event)
    str.should eq("part1part2")
  ensure
    reader.try &.close
    writer.try &.close
  end

  it "input1 reads one character without events" do
    reader, writer = IO.pipe

    ::spawn do
      writer << "xy"
      writer.flush
      writer.close
    end

    instream = CML::StreamIO.open_text_in(reader)
    result = CML::StreamIO.input1(instream)
    result.should_not be_nil
    char, stream2 = result.not_nil!
    char.should eq('x')

    result2 = CML::StreamIO.input1(stream2)
    result2.should_not be_nil
    char2, _stream3 = result2.not_nil!
    char2.should eq('y')
  ensure
    reader.try &.close
    writer.try &.close
  end

  it "input_n and input_all read data without events" do
    reader, writer = IO.pipe

    ::spawn do
      writer << "hello"
      writer.flush
      writer.close
    end

    instream = CML::StreamIO.open_text_in(reader)
    chunk, stream2 = CML::StreamIO.input_n(instream, 2)
    chunk.should eq("he")

    rest, _stream3 = CML::StreamIO.input_all(stream2)
    rest.should eq("llo")
  ensure
    reader.try &.close
    writer.try &.close
  end

  it "output writes text data" do
    io = IO::Memory.new
    begin
      outstream = CML::StreamIO.open_text_out(io)
      outstream = CML::StreamIO.output(outstream, "hi")
      outstream = CML::StreamIO.output1(outstream, '!')
      CML::StreamIO.flush_out(outstream)
      io.to_s.should eq("hi!")
    ensure
      io.close
    end
  end

  # Note: choose requires all events to have the same type parameter,
  # so you cannot choose between a stream event and a channel event
  # unless they return the same type. This is consistent with SML/NJ CML.
end
