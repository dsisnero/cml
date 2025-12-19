# advanced_patterns_023.cr
# Extracted from: how_to.md
# Section: advanced_patterns
# Lines: 920-983
#
# ----------------------------------------------------------

require "../../src/cml"

class LockServer
  enum Request
    Acquire
    Release
  end

  def initialize
    @req_ch = CML::Chan({Int32, Request, CML::Chan(Bool)?}).new
    @locks = Hash(Int32, Bool).new(false)

    CML.spawn { server_loop }
  end

  private def server_loop
    loop do
      lock_id, req_type, reply_ch = CML.sync(@req_ch.recv_evt)

      case req_type
      when Request::Acquire
        if !@locks[lock_id]?
          @locks[lock_id] = true
          reply_ch.try &.send(true)
        else
          reply_ch.try &.send(false)
        end
      when Request::Release
        @locks.delete(lock_id)
      end
    end
  end

  def acquire(lock_id : Int32) : Bool
    reply_ch = CML::Chan(Bool).new
    CML.sync(@req_ch.send_evt({lock_id, Request::Acquire, reply_ch}))
    CML.sync(reply_ch.recv_evt)
  end

  def release(lock_id : Int32)
    CML.sync(@req_ch.send_evt({lock_id, Request::Release, nil}))
  end
end

# Usage
server = LockServer.new

# Try to acquire same lock from multiple threads
lock_id = 1
5.times do |i|
  CML.spawn do
    if server.acquire(lock_id)
      puts "Thread #{i} acquired lock"
      sleep 0.05
      server.release(lock_id)
      puts "Thread #{i} released lock"
    else
      puts "Thread #{i} failed to acquire lock"
    end
  end
end

sleep 0.3