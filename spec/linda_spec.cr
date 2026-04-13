require "./spec_helper"

describe "CML::Linda tuple space" do
  it "exposes helper constructors directly on Linda module" do
    atom = CML::Linda.sval("x")
    pat = CML::Linda.sform
    atom.value.should eq("x")
    pat.kind.string_formal?.should be_true
  end

  it "supports out and in_evt" do
    space = CML::Linda::TupleSpace.new
    tuple = CML::Linda::TupleRep(CML::Linda::ValAtom).new(CML::Linda::Helpers.ival(1), [CML::Linda::Helpers.sval("x")])
    template = CML::Linda::TupleRep(CML::Linda::PatAtom).new(CML::Linda::Helpers.ival(1), [CML::Linda::Helpers.sform])

    ::spawn do
      space.out(tuple)
    end

    bindings = CML.sync(space.in_evt(template))
    bindings.size.should eq(1)
    bindings.first.value.should eq("x")
  end

  it "supports rd_evt without consuming" do
    space = CML::Linda::TupleSpace.new
    tuple = CML::Linda::TupleRep(CML::Linda::ValAtom).new(CML::Linda::Helpers.sval("tag"), [CML::Linda::Helpers.bval(true)])
    template = CML::Linda::TupleRep(CML::Linda::PatAtom).new(CML::Linda::Helpers.sval("tag"), [CML::Linda::Helpers.bform])
    space.out(tuple)

    bindings1 = CML.sync(space.rd_evt(template))
    bindings2 = CML.sync(space.rd_evt(template))

    bindings1.first.value.should be_true
    bindings2.first.value.should be_true
  end
end
