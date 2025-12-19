# common_pitfalls_and_solutions_032.cr
# Extracted from: how_to.md
# Section: common_pitfalls_and_solutions
# Lines: 1292-1310
#
# ----------------------------------------------------------

require "../../src/cml"

# Dummy definitions for example compilation
def acquire_resource
  nil
end

def release_resource(resource)
end

# Always clean up resources
def with_resource(&)
  resource = acquire_resource()

  begin
    yield resource
  ensure
    release_resource(resource)
  end
end

# Use in CML thread
CML.spawn do
  with_resource do |resource|
    # Use resource
  end
end