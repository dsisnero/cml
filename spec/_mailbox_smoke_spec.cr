require "./spec_helper"
require "../src/cml/mailbox.cr"

describe CML do
  it "mailbox smoke" do
    mb = CML::Mailbox(Int32).new
    mb.send(1)
    CML.sync(mb.recv_evt).should eq(1)
  end
end
