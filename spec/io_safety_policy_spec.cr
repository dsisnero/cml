require "./spec_helper"

describe "CML IO safety policy" do
  it "forbids direct socket IO in distributed tuple transport" do
    source = File.read("src/cml/tuple.cr")

    forbidden = [
      /socket\.read\(/,
      /socket\.write\(/,
      /socket\.read_fully\(/,
      /socket\.read_bytes\(/,
      /socket\.write_bytes\(/,
      /socket\.wait_readable\(/,
      /socket\.wait_writable\(/,
    ]

    matches = forbidden.compact_map do |pattern|
      source.match(pattern).try(&.[0]?)
    end

    matches.should be_empty, "tuple transport must use CML socket events, found: #{matches.join(", ")}"
    source.should contain("CML::Socket.send_evt(")
    source.should contain("CML::Socket.recv_evt(")
  end
end
