# Chat Demo Example for CML
# Demonstrates a simple chat room with multiple senders and receivers using CML channels and events.

require "../src/cml"

class ChatRoom
  def initialize
    @chan = CML::Chan(String).new
  end

  def post(msg : String)
    CML.sync(@chan.send_evt(msg))
  end

  def subscribe(name : String, n : Int32 = 3)
    spawn do
      n.times do
        msg = CML.sync(@chan.recv_evt)
        puts "[#{name}] got: #{msg}"
      end
    end
  end
end

room = ChatRoom.new

# Start two subscribers
room.subscribe("alice")
room.subscribe("bob")

# Start two senders
spawn { ["hi", "how are you?", "bye"].each { |msg| room.post("alice: #{msg}") } }
spawn { ["hello", "fine!", "see ya"].each { |msg| room.post("bob: #{msg}") } }

# Wait for all messages to be delivered
sleep 0.5
