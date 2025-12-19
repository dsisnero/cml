# understanding_cmls_non-blocking_architecture_038.cr
# Extracted from: how_to.md
# Section: understanding_cmls_non-blocking_architecture
# Lines: 1445-1456
#
# ----------------------------------------------------------

require "../../src/cml"

# Server loop
def loop(current_value)
  request = CML.sync(@req_ch.recv_evt) # Only blocking point
  # Process request immediately
  case request
  when :get then send_reply(current_value)
  when T    then update_value(request)
  end
  loop(...) # Tail recursion - constant stack usage
end
