require "./spec_helper.cr"

describe CML::Result do
  it "returns the value that was put" do
    result = CML::Result(Int32).new
    result.put(42)
    result.get.should eq(42)
  end

  it "raises the exception that was put" do
    result = CML::Result(Int32).new
    result.put_exn(ArgumentError.new("bad"))

    expect_raises(ArgumentError) do
      result.get
    end
  end

  it "wraps get_evt for values" do
    result = CML::Result(String).new
    result.put("ok")
    CML.sync(result.get_evt).should eq("ok")
  end

  it "wraps get_evt for exceptions" do
    result = CML::Result(String).new
    result.put_exn(RuntimeError.new("boom"))

    expect_raises(RuntimeError) do
      CML.sync(result.get_evt)
    end
  end
end
