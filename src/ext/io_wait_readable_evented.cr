require "io/evented"

# Evented wait helpers using the Crystal event loop.
class IO
  def wait_readable(timeout : Time::Span? = nil, *, raise_if_closed : Bool = true) : Bool
    return false if closed? && raise_if_closed
    return true unless is_a?(IO::Evented)

    timed_out = false
    evented_wait_readable(timeout, raise_if_closed: raise_if_closed) do
      timed_out = true
    end
    !timed_out
  end

  def wait_writable(timeout : Time::Span? = nil) : Bool
    return true unless is_a?(IO::Evented)

    timed_out = false
    evented_wait_writable(timeout) do
      timed_out = true
    end
    !timed_out
  end
end
