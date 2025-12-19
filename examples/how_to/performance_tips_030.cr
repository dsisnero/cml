# performance_tips_030.cr
# Extracted from: how_to.md
# Section: performance_tips
# Lines: 1200-1238
#
# ----------------------------------------------------------

require "../../src/cml"

class WorkerPool(T, R)
  def initialize(@worker_count : Int32, &block : T -> R)
    @task_ch = CML::Chan({T, CML::Chan(R)}).new

    @worker_count.times do
      CML.spawn do
        loop do
          task, reply_ch = CML.sync(@task_ch.recv_evt)
          result = block.call(task)
          CML.sync(reply_ch.send_evt(result))
        end
      end
    end
  end

  def submit(task : T) : R
    reply_ch = CML::Chan(R).new
    CML.sync(@task_ch.send_evt({task, reply_ch}))
    CML.sync(reply_ch.recv_evt)
  end
end

# Usage
pool = WorkerPool(Int32, Int32).new(4) do |x|
  sleep 0.1 # Simulate work
  x * 2
end

# Submit multiple tasks
10.times do |i|
  CML.spawn do
    result = pool.submit(i)
    puts "Task #{i} -> #{result}"
  end
end

sleep 0.3
