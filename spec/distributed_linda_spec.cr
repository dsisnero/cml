require "./spec_helper"

describe "CML::DistributedLinda" do
  it "creates a local tuple space with join_tuple_space" do
    space = CML::Linda.join_tuple_space
    tuple = CML::Linda::TupleRep(CML::Linda::ValAtom).new(
      CML::Linda::Helpers.ival(1),
      [CML::Linda::Helpers.sval("test")]
    )
    template = CML::Linda::TupleRep(CML::Linda::PatAtom).new(
      CML::Linda::Helpers.ival(1),
      [CML::Linda::Helpers.sform]
    )

    ::spawn do
      space.out(tuple)
    end

    bindings = CML.sync(space.in_evt(template))
    bindings.size.should eq(1)
    bindings.first.value.should eq("test")
  end

  it "supports non-destructive reads" do
    space = CML::Linda.join_tuple_space
    tuple = CML::Linda::TupleRep(CML::Linda::ValAtom).new(
      CML::Linda::Helpers.sval("tag"),
      [CML::Linda::Helpers.ival(42)]
    )
    template = CML::Linda::TupleRep(CML::Linda::PatAtom).new(
      CML::Linda::Helpers.sval("tag"),
      [CML::Linda::Helpers.iform]
    )
    space.out(tuple)

    bindings1 = CML.sync(space.rd_evt(template))
    bindings2 = CML.sync(space.rd_evt(template))

    bindings1.first.value.should eq(42)
    bindings2.first.value.should eq(42)
  end

  # This test requires network support - commented out for now
  # it "can create distributed tuple space with local port" do
  #   # Start a tuple server on a random port
  #   space1 = CML::Linda.join_tuple_space(local_port: 0)
  #   # This should create a distributed tuple space with network server
  #   # We can't easily test without connecting, but at least ensure no crash
  #   space1.should be_a(CML::Linda::TupleSpace)
  # end
end
