# Aggregator for the CML-Linda example (ports the SML/NJ CML-Linda interface).
require "./linda/linda"

# require "./distributed_linda"

module CML::Linda
  # Override join_tuple_space to support distributed tuple spaces
  # when remote hosts or local port are specified
  def self.join_tuple_space(local_port : Int32? = nil, remote_hosts : Array(String) = [] of String) : TupleSpace
    # Distributed Linda temporarily disabled
    TupleSpace.new
  end
end
