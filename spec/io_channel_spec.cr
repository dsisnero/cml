require "./spec_helper"

describe "CML channel-backed IO helpers" do
  it "writes via ChannelOutIO and reads via ChannelInIO" do
    ch = CML.channel(String)
    reader = CML.open_chan_in(ch)
    writer = CML.open_chan_out(ch)

    ::spawn do
      writer.write("hello\n".to_slice)
      writer.write("world".to_slice)
      writer.flush
      writer.close
    end

    first = reader.gets
    second = reader.read_string(5)

    first.should eq("hello")
    second.should eq("world")
  end
end
