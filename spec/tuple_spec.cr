require "./spec_helper"

private def sync_with_timeout(evt : CML::Event(T), timeout = 1.second) : T forall T
  result = CML.sync(CML.choose(evt, CML.timeout(timeout)))
  result.should_not be_nil
  result.as(T)
end

describe "CML::TupleLib" do
  it "supports out and in_evt" do
    CML.set_running(false)
    begin
      CML.run do
        ts = CML::TupleLib::TupleSpace.join_tuple_space

        tuple = CML::TupleLib::TupleRep(CML::TupleLib::ValAtom).new(
          CML::TupleLib::Helpers.sval("k"),
          [CML::TupleLib::Helpers.ival(42)]
        )

        template = CML::TupleLib::TupleRep(CML::TupleLib::PatAtom).new(
          CML::TupleLib::Helpers.sval("k"),
          [CML::TupleLib::Helpers.iform]
        )

        CML.spawn { ts.out(tuple) }
        result = sync_with_timeout(ts.in_evt(template))

        result.size.should eq(1)
        result.first.value.should eq(42)
      end
    ensure
      CML.set_running(true)
    end
  end

  it "supports rd_evt without consuming tuple" do
    CML.set_running(false)
    begin
      CML.run do
        ts = CML::TupleLib::TupleSpace.join_tuple_space

        tuple = CML::TupleLib::TupleRep(CML::TupleLib::ValAtom).new(
          CML::TupleLib::Helpers.sval("peek"),
          [CML::TupleLib::Helpers.bval(true)]
        )

        template = CML::TupleLib::TupleRep(CML::TupleLib::PatAtom).new(
          CML::TupleLib::Helpers.sval("peek"),
          [CML::TupleLib::Helpers.bform]
        )

        ts.out(tuple)

        r1 = sync_with_timeout(ts.rd_evt(template))
        r2 = sync_with_timeout(ts.rd_evt(template))
        r3 = sync_with_timeout(ts.in_evt(template))

        r1.first.value.should be_true
        r2.first.value.should be_true
        r3.first.value.should be_true
      end
    ensure
      CML.set_running(true)
    end
  end

  it "uses chapter-9 formal atom wire tags for template encoding" do
    template = CML::TupleLib::TupleRep(CML::TupleLib::PatAtom).new(
      CML::TupleLib::Helpers.sval("wire"),
      [CML::TupleLib::Helpers.bform, CML::TupleLib::Helpers.sform]
    )
    encoded = CML::TupleLib::DataRep.encode_template(template)
    encoded.should contain("y;")
    encoded.should contain("z;")
  end

  it "accepts bracketed IPv6 remote host syntax without parse errors" do
    begin
      CML::TupleLib::TupleSpace.join_tuple_space(
        remote_hosts: ["[::1]:65000"]
      )
      fail "expected remote connection failure"
    rescue ex : ArgumentError
      fail "expected host parsing to accept bracketed IPv6: #{ex.message}"
    rescue ex : ::Socket::Error
      ex.message.should_not be_nil
      ex.message.not_nil!.should contain("failed to connect to remote tuple space")
    end
  end
end
