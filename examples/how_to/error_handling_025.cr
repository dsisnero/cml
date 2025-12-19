# error_handling_025.cr
# Extracted from: how_to.md
# Section: error_handling
# Lines: 1057-1082
#
# ----------------------------------------------------------

require "../../src/cml"

def safe_divide(a : Int32, b : Int32) : CML::Event(Float64)
  CML.guard do
    if b == 0
      CML.always(0.0) # Default value on error
    else
      CML.always(a.to_f / b)
    end
  end
end

# Or with wrap_handler for exception handling
def safe_divide_with_handler(a : Int32, b : Int32) : CML::Event(Float64)
  CML.wrap_handler(CML.guard { CML.always(a.to_f / b) }) do |ex|
    puts "Division error: #{ex.message}"
    CML.always(0.0)
  end
end

# Usage
result = CML.sync(safe_divide(10, 2))
puts "10 / 2 = #{result}" # => 5.0

result = CML.sync(safe_divide(10, 0))
puts "10 / 0 = #{result}" # => 0.0