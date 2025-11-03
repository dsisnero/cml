# src/cml/multicast.cr
# CML Multicast channel: multiple subscribers receive every broadcast message
#
# Implements the SML structure:
#   Multicast : sig
#     type 'a mchan
#     type 'a port
#     val mChannel : unit -> 'a mchan
#     val multicast : 'a mchan * 'a -> unit
#     val port : 'a mchan -> 'a port
#     val recv_evt : 'a port -> 'a event
#   end

require "../cml"
require "./mailbox"

module CML
  # Represents a subscriber port with a mailbox
  struct Port(T)
    getter mailbox : Mailbox(T)

    def initialize(@mailbox : Mailbox(T))
    end
  end

  # Requests handled by the multicast server
  enum RequestType
    Message
    NewPort
  end

  record Request(T),
    kind : RequestType,
    value : T? = nil

  # The multicast channel itself
  class MChan(T)
    @req_ch = CML::Chan(Request(T)).new
    @reply_ch = CML::Chan(Port(T)).new
    @subscribers = [] of Mailbox(T)

    getter req_ch
    getter reply_ch

    def initialize
      spawn { server } # start server with empty subscribers
    end

    # Send a message to all subscribers
    def multicast(msg : T)
      CML.sync(@req_ch.send_evt(Request(T).new(RequestType::Message, msg)))
    end

    # Create a new subscriber port
    def new_port : Port(T)
      CML.sync(@req_ch.send_evt(Request(T).new(RequestType::NewPort)))
      CML.sync(@reply_ch.recv_evt)
    end

    # (mk_port removed; server creates ports directly)

    # Internal: multicast server loop
    private def server
      loop do
        req = CML.sync(@req_ch.recv_evt)
        case req.kind
        when RequestType::NewPort
          mbox = Mailbox(T).new
          @subscribers << mbox
          port = Port(T).new(mbox)
          CML.sync(@reply_ch.send_evt(port))
        when RequestType::Message
          msg = req.value.as(T)
          @subscribers.each(&.send(msg))
        end
      end
    end
  end

  # Utility API for client-style access
  def self.m_channel(type : T.class) forall T
    MChan(T).new
  end

  def self.multicast(chan : MChan(T), msg : T) forall T
    chan.multicast(msg)
  end

  def self.port(chan : MChan(T)) : Port(T) forall T
    chan.new_port
  end

  def self.recv_evt(port : Port(T)) : Event(T) forall T
    port.mailbox.recv_evt
  end
end
