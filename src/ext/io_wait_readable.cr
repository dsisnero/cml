# Minimal wait stubs for environments without evented IO support available.
class IO
  def wait_readable(timeout : Time::Span? = nil, *, raise_if_closed : Bool = true) : Bool
    return false if closed? && raise_if_closed
    sleep timeout if timeout
    true
  end

  def wait_writable(timeout : Time::Span? = nil) : Bool
    sleep timeout if timeout
    true
  end
end
