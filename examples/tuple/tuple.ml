(* CML Implementation of Linda - Chapter 9 of Cambridge Concurrent Programming in ML *)
(* Organized into coherent modules following the book's architecture *)
(* This is a conceptual implementation; many dependencies on SML/NJ and CML are assumed. *)

(* Preamble: Assume necessary CML and library structures are available *)
open CML  (* assume CML provides sync, spawn, channel, sendEvt, recvEvt, wrap, select, withNack *)
structure Mailbox = CMLMailbox  (* mailbox library *)
structure Multicast = CMLMulticast
structure SimpleRPC = CMLSimpleRPC
structure SyncVar = CMLSyncVar
structure HashTableFn = HashTableFn  (* from SML/NJ Library *)
structure Hash2TableFn = Hash2TableFn

(* Utility functions referenced but not defined in the chapter *)
fun error msg = raise Fail msg
fun hashTid (tid : thread_id) = Word.fromInt (tid : int)  (* dummy *)
fun sameTid (tid1 : thread_id, tid2 : thread_id) = (tid1 = tid2)
fun getTid () = 0  (* dummy thread ID *)
fun think _ = ()
fun eat _ = ()

(* Note: The following SML/NJ Library modules are assumed:
   Socket, INetSock, NetHostDB, SockUtil, Pack16Big, Pack32Big, Word8Vector, Word8Array
   They are not implemented here.
*)

(* =========================================================================== *)
(* Tuple Types *)
(* =========================================================================== *)

structure Tuple = struct
  datatype val_atom
    = IVal of int
    | SVal of string
    | BVal of bool

  datatype pat_atom
    = IPat of int
    | SPat of string
    | BPat of bool
    | IFormal
    | SFormal
    | BFormal
    | Wild

  datatype 'a tuple_rep = T of (val_atom * 'a list)

  type tuple = val_atom tuple_rep
  type template = pat_atom tuple_rep

  (* Helper function to extract tag from tuple/template *)
  fun key (T (tag, _)) = tag
end

(* =========================================================================== *)
(* DataRep: Marshalling and unmarshalling of tuples and templates *)
(* =========================================================================== *)

signature DATA_REP =
sig
  type vector = Word8Vector.vector
  val decodeTuple   : (vector * int) -> (Tuple.tuple * int)
  val decodeTemplate : (vector * int) -> (Tuple.template * int)
  val decodeValues   : (vector * int) -> (Tuple.val_atom list * int)

  type array = Word8Array.array
  val encodeTuple   : (Tuple.tuple * array * int) -> int
  val encodeTemplate : (Tuple.template * array * int) -> int
  val encodeValues   : (Tuple.val_atom list * array * int) -> int

  val tupleSz    : Tuple.tuple -> int
  val templateSz : Tuple.template -> int
  val valuesSz   : Tuple.val_atom list -> int
end

structure DataRep : DATA_REP = struct
  (* Implementation not shown in book - placeholder *)
  type vector = Word8Vector.vector
  type array = Word8Array.array
  fun decodeTuple (v, i) = raise Fail "DataRep.decodeTuple not implemented"
  fun decodeTemplate (v, i) = raise Fail "DataRep.decodeTemplate not implemented"
  fun decodeValues (v, i) = raise Fail "DataRep.decodeValues not implemented"
  fun encodeTuple (t, a, i) = raise Fail "DataRep.encodeTuple not implemented"
  fun encodeTemplate (t, a, i) = raise Fail "DataRep.encodeTemplate not implemented"
  fun encodeValues (vs, a, i) = raise Fail "DataRep.encodeValues not implemented"
  fun tupleSz t = raise Fail "DataRep.tupleSz not implemented"
  fun templateSz t = raise Fail "DataRep.templateSz not implemented"
  fun valuesSz vs = raise Fail "DataRep.valuesSz not implemented"
end

(* =========================================================================== *)
(* NetMessage: Network message types and socket I/O *)
(* =========================================================================== *)

structure NetMessage = struct
  datatype message
    = OutTuple of Tuple.tuple
    | InReq of {
        transId : int,
        pat : Tuple.template
      }
    | RdReq of {
        transId : int,
        pat : Tuple.template
      }
    | Accept of { transId : int }
    | Cancel of { transId : int }
    | InReply of {
        transId : int,
        vals : Tuple.val_atom list
      }

  type 'a sock = ('a, Socket.active Socket.stream) Socket.sock

  structure DR = DataRep

  fun recvMessage sock = let
      val hdr = SockUtil.recvVec (sock, 4)
      val kind = Pack16Big.subVec(hdr, 0)
      val len = LargeWord.toInt(Pack16Big.subVec(hdr, 1))
      val data = SockUtil.recvVec (sock, len)
      fun getId () = LargeWord.toInt(Pack32Big.subVec(data, 0))
      fun getTuple () = #1 (DR.decodeTuple (data, 0))
      fun getPat () = #1 (DR.decodeTemplate (data, 4))
      fun getVals () = #1 (DR.decodeValues (data, 4))
      in
        case kind
          of 0w0 => OutTuple(getTuple ())
          | 0w1 => InReq{transId=getId(), pat=getPat()}
          | 0w2 => RdReq{transId=getId(), pat=getPat()}
          | 0w3 => Accept{transId=getId()}
          | 0w4 => Cancel{transId=getId()}
          | 0w5 => InReply{transId=getId(), vals=getVals()}
          | _ => error "recvMessage: bogus message kind"
      (* end case *)
    end

  (* sendMessage omitted in book - placeholder *)
  fun sendMessage (sock, msg) = raise Fail "NetMessage.sendMessage not implemented"
end

(* =========================================================================== *)
(* Network: Abstract network interface *)
(* =========================================================================== *)

signature NETWORK =
sig
  type network
  type server_conn
  eqtype ts_id

  type reply = {transId : int, vals : Tuple.val_atom list}

  datatype client_req
    = OutTuple of Tuple.tuple
    | InReq of {
        from : ts_id,
        transId : int,
        remove : bool,
        pat : Tuple.template,
        reply : reply -> unit
    }
    | Accept of {from : ts_id, transId : int}
    | Cancel of {from : ts_id, transId : int}

  type remote_server_info = {
        name : string,
        id : ts_id,
        conn : server_conn
      }

  val initNetwork : {
        port    : int option,
        remote  : string list,
        tsReqMb : client_req Mailbox.mbox,
        addTS   : remote_server_info -> unit
      } -> {
        myId    : ts_id,
        network : network,
        servers : remote_server_info list
      }

  val sendOutTuple : server_conn -> Tuple.tuple -> unit
  val sendInReq : server_conn -> {
        transId : int,
        remove : bool,
        pat : Tuple.template
      } -> unit
  val sendAccept   : server_conn -> {transId : int} -> unit
  val sendCancel   : server_conn -> {transId : int} -> unit
  val replyEvt     : server_conn -> reply event

  val shutdown : network -> unit

end (* NETWORK *)

structure Network : NETWORK = struct
  datatype network = NETWORK of {shutdown: unit SyncVar.ivar}
  datatype server_conn = CONN of {
        out : NetMessage.message -> unit,
        replyEvt : reply event
      }

  type ts_id = int
  type reply = {transId : int, vals : Tuple.val_atom list}

  datatype client_req
    = OutTuple of Tuple.tuple
    | InReq of {
        from : ts_id,
        transId : int,
        remove : bool,
        pat : Tuple.template,
        reply : reply -> unit
    }
    | Accept of {from : ts_id, transId : int}
    | Cancel of {from : ts_id, transId : int}

  type remote_server_info = {
        name : string,
        id : ts_id,
        conn : server_conn
      }

  (* Helper functions *)
  fun error msg = raise Fail msg

  fun parseHost h = (case (StringCvt.scanString SockUtil.scanAddr h)
        of NONE => error "bad hostname format"
        | (SOME info) => (case SockUtil.resolveAddr info
            of {host, addr, port = NONE} =>
                {host = host, addr = addr, port = 7001}
            | {host, addr, port = SOME p} =>
                {host = host, addr = addr, port = p}
            (* end case *))
            handle (SockUtil.BadAddr msg) => error msg
    (* end case *))

  fun spawnBuffers (id, sock, tsMb) = let
        val outMb = Mailbox.mailbox()
        fun outLoop () = (
              NetMessage.sendMessage (sock, Mailbox.recv outMb);
              outLoop())
        val inMb = Mailbox.mailbox()
        fun reply r = Mailbox.send(outMb, NetMessage.InReply r)
        fun inLoop () = (
              case NetMessage.recvMessage sock
              of (NetMessage.OutTuple t) => Mailbox.send(tsMb, OutTuple t)
              | (NetMessage.InReq{transId, pat}) =>
                  Mailbox.send(tsMb, InReq{
                      from=id, transId=transId,
                      remove = true, pat=pat, reply=reply
                  })
              | (NetMessage.RdReq{transId, pat}) =>
                  Mailbox.send(tsMb, InReq{
                      from=id, transId=transId,
                      remove = false, pat=pat, reply=reply
                  })
              | (NetMessage.Accept{transId}) =>
                  Mailbox.send(tsMb, Accept{from=id, transId=transId})
              | (NetMessage.Cancel{transId}) =>
                  Mailbox.send(tsMb, Cancel{from=id, transId=transId})
              | (NetMessage.InReply repl) => Mailbox.send(inMb, repl)
              (* end case *);
              inLoop ())
        in
          spawn outLoop; spawn inLoop;
          CONN{
              out = fn req => Mailbox.send(outMb, req),
              replyEvt = Mailbox.recvEvt inMb
          }
    end

  fun spawnNetServer (myPort, startId, tsMb, addTS) = let
      val mySock = INetSock.TCP.socket()
      fun loop nextId = let
              val (newSock, addr) = Socket.accept mySock
              val proxyConn = spawnBuffers (nextId, newSock, tsMb)
              val (host, port) = INetSock.fromAddr addr
              val name = (case NetHostDB.getByAddr host
                      of (SOME ent) => NetHostDB.name ent
                      | NONE => "??"
                      (* end case *))
              in
                  addTS {name = name, id = nextId, conn = proxyConn};
                  loop (nextId+1)
              end
      val port = getOpt(myPort, 7001)
      in
        Socket.bind (mySock, INetSock.any port);
        Socket.listen (mySock, 5);
        spawn (fn () => loop startId);
        NETWORK{shutdown = SyncVar.iVar()}
      end

  fun initNetwork {port, remote, tsReqMb, addTS} = let
        val hosts = List.map parseHost remote
        val startId = length hosts + 1
        val network = spawnNetServer (port, startId, tsReqMb, addTS)
        fun mkServer ({host, addr, port}, (id, l)) = let
              val sock = INetSock.TCP.socket()
              val sockAddr = INetSock.toAddr(addr, port)
              val _ = Socket.connect (sock, sockAddr)
              val conn = spawnBuffers (id, sock, tsReqMb)
              in
                (id+1, {name = host, id = id, conn = conn}::l)
              end
        in
          { myId = 0, network = network,
            servers = #2 (List.foldl mkServer (1, []) hosts)
          }
        end

  (* Stub implementations for send operations *)
  fun sendOutTuple (CONN{out, ...}) tuple = out (NetMessage.OutTuple tuple)
  fun sendInReq (CONN{out, ...}) {transId, remove, pat} =
        out (if remove then NetMessage.InReq{transId=transId, pat=pat}
                       else NetMessage.RdReq{transId=transId, pat=pat})
  fun sendAccept (CONN{out, ...}) {transId} = out (NetMessage.Accept{transId=transId})
  fun sendCancel (CONN{out, ...}) {transId} = out (NetMessage.Cancel{transId=transId})
  fun replyEvt (CONN{replyEvt, ...}) = replyEvt

  fun shutdown (NETWORK{shutdown}) = SyncVar.iGet shutdown  (* placeholder *)
end

(* =========================================================================== *)
(* TupleStore: Storage mechanism for local portion of tuple space *)
(* =========================================================================== *)

signature TUPLE_STORE =
sig

  type tuple_store
  type id = (Network.ts_id * int)
  type 'a match = {
      id    : id,
      reply : Network.reply -> unit,
      ext   : 'a
    }
  type bindings = Tuple.val_atom list

  val newStore : unit -> tuple_store

  val add : (tuple_store * Tuple.tuple) -> bindings match option
  val input : (tuple_store * Tuple.template match) -> bindings option
  val cancel : (tuple_store * id) -> bindings match option
  val remove : (tuple_store * id) -> unit

end

structure TupleStore : TUPLE_STORE = struct
  structure T = Tuple
  structure Net = Network

  type id = (Net.ts_id * int)
  type 'a match = {
      id    : id,
      reply : Net.reply -> unit,
      ext   : 'a
    }
  type bindings = T.val_atom list

  type bucket = {
      waiting : T.template match list ref,
      holds   : (id * T.tuple) list ref,
      items   : T.tuple list ref
    }

  structure TupleTbl = HashTableFn (struct
          type hash_key = T.val_atom
          fun hashVal (T.BVal false) = 0w0
            | hashVal (T.BVal true) = 0w1
            | hashVal (T.IVal n) = Word.fromInt n
            | hashVal (T.SVal s) = HashString.hashString s
          fun sameKey (k1 : T.val_atom, k2) = (k1 = k2)
      end)

  structure QueryTbl = HashTableFn (struct
          type hash_key = id
          fun hashVal (_, id) = Word.fromInt id
          fun sameKey ((tsId1, id1), (tsId2, id2) : hash_key) =
              ((tsId1 = tsId2) andalso (id1 = id2))
      end)

  datatype query_status = Held | Waiting

  datatype tuple_store = TS of {
      queries : (query_status * bucket) QueryTbl.hash_table,
      tuples : bucket TupleTbl.hash_table
    }

  (* Helper function to remove an element from a list satisfying a predicate *)
  fun removeFromList pred [] = raise Empty
    | removeFromList pred (x::xs) =
        if pred x then (x, xs) else let val (y, ys) = removeFromList pred xs in (y, x::ys) end

  fun match (T.T(_, rest1), T.T(_, rest2)) = let
        fun mFields ([], [], binds) = SOME binds
          | mFields (f1::r1, f2::r2, binds) = (
            case mField(f1, f2, binds)
              of (SOME binds) => mFields(r1, r2, binds)
              | NONE => NONE
            (* end case *))
          | mFields _ = NONE
        and mField (T.IPat a, T.IVal b, binds) =
          if (a = b) then SOME binds else NONE
        | mField (T.BPat a, T.BVal b, binds) =
          if (a = b) then SOME binds else NONE
        | mField (T.SPat a, T.SVal b, binds) =
          if (a = b) then SOME binds else NONE
        | mField (T.IFormal, x as (T.IVal _), binds) =
          SOME(x::binds)
        | mField (T.BFormal, x as (T.BVal _), binds) =
          SOME(x::binds)
        | mField (T.SFormal, x as (T.SVal _), binds) =
          SOME(x::binds)
        | mField (T.Wild, _, binds) = SOME binds
        | mField _ = NONE
    in
      mFields (rest1, rest2, [])
    end

  fun newStore () = TS{
        queries = QueryTbl.mkTable (32, Fail "QueryTbl"),
        tuples = TupleTbl.mkTable (32, Fail "TupleTbl")
      }

  fun add (TS{tuples, queries}, tuple as T.T(key, _)) = (
        case (TupleTbl.find tuples key)
        of NONE => (
            TupleTbl.insert tuples (key, {
                items = ref [tuple],
                waiting = ref[],
                holds = ref[]
            });
            NONE)
        | (SOME(bucket as {items, waiting, holds})) => let
            fun scan ([], _) = (items := tuple :: !items; NONE)
            | scan ((x as {reply, id, ext})::r, wl) = (
                case match(ext, tuple)
                of NONE => scan(r, x::wl)
                | (SOME binds) => (
                    waiting := List.revAppend(wl, r);
                    holds := (id, tuple) :: !holds;
                    QueryTbl.insert queries (id, (Held, bucket));
                    SOME{reply=reply, id=id, ext=binds})
                (* end case *))
            in
                scan (!waiting, [])
            end
    (* end case *))

  fun input (TS{tuples, queries}, {reply, ext as T.T(key, _), id}) = (
        case (TupleTbl.find tuples key)
        of NONE => let
            val bucket = {
                waiting = ref[{reply=reply, id=id, ext=ext}],
                holds = ref[],
                items = ref[]
            }
        in
            TupleTbl.insert tuples (key, bucket);
            QueryTbl.insert queries (id, (Waiting, bucket));
            NONE
        end
    | (SOME(bucket as {items, waiting, holds})) => let
        fun look (_, []) = (
                waiting := !waiting @
                    [{reply=reply, id=id, ext=ext}],
                QueryTbl.insert queries (id, (Waiting, bucket));
                NONE)
        | look (prefix, item :: r) = (
            case match(ext, item)
                of NONE => look (item::prefix, r)
                | (SOME binds) => (
                    items := List.revAppend(prefix, r);
                    holds := (id, item) :: !holds;
                    QueryTbl.insert queries (id, (Held, bucket));
                    SOME binds)
            (* end case *))
        in
            look ([], !items)
        end
    (* end case *))

  fun cancel (tbl as TS{tuples, queries}, id) = (
      case (QueryTbl.remove queries id)
        of (Waiting, {items, waiting, holds}) => (
            case (removeFromList (fn t => (#id t = id)) (! waiting))
              of ({ext, ...}, []) =>
                if (null(! items) andalso null(! holds))
                  then ignore(TupleTbl.remove tuples (T.key ext))
                  else waiting := []
                | (_, l) => waiting := l
              (* end case *);
              NONE)
          | (Held, {items, waiting, holds}) => let
              val ((_, tuple), l) =
                  removeFromList (fn (id', _) => (id' = id)) (! holds)
              in
                holds := l;
                add (tbl, tuple)
              end
          (* end case *))

  fun remove (tbl as TS{tuples, queries}, id) = let
        val (_, {items, waiting, holds}) = QueryTbl.remove queries id
        val ((_, tuple), l) =
            removeFromList (fn (id', _) => (id' = id)) (! holds)
        in
          if (null l andalso null(! items) andalso null(! waiting))
            then ignore(TupleTbl.remove tuples (T.key tuple))
            else holds := l
        end

end

(* =========================================================================== *)
(* TupleServer: Local tuple server, proxies, and log server *)
(* =========================================================================== *)

signature TUPLE_SERVER =
sig
  type ts_id = Network.ts_id

  datatype ts_msg
    = IN of {
          tid : thread_id,
          remove : bool,
          pat : Tuple.template,
          replFn : (Tuple.val_atom list * ts_id) -> unit
        }
    | CANCEL of thread_id
    | ACCEPT of (thread_id * ts_id)

  val mkLogServer : ts_msg Multicast.port
        -> unit -> (ts_msg Multicast.port * ts_msg list)
  val mkTupleServer :
        (ts_id * Network.client_req Mailbox.mbox * ts_msg event)
        -> unit
  val mkProxyServer :
        (ts_id * Network.server_conn * ts_msg event * ts_msg list)
        -> unit

end

structure TupleServer : TUPLE_SERVER = struct
  structure T = Tuple
  structure Net = Network
  structure MChan = Multicast

  type ts_id = Net.ts_id

  datatype ts_msg
    = IN of {
          tid : thread_id,
          remove : bool,
          pat : T.template,
          replFn : (T.val_atom list * ts_id) -> unit
        }
    | CANCEL of thread_id
    | ACCEPT of (thread_id * ts_id)

  structure TransTbl = Hash2TableFn (
      structure Key1 = struct
          type hash_key = thread_id
          val hashVal = hashTid
          val sameKey = sameTid
      end
      structure Key2 = struct
          type hash_key = int
          val hashVal = Word.fromInt
          val sameKey = (op = : (int * int) -> bool)
      end)

  type trans_info = {
      id : int,
      replFn : (T.val_atom list * ts_id) -> unit
    }

  type conn_ops = {
      sendInReq  : {
          transId : int, remove : bool, pat : T.template
        } -> unit,
      sendAccept : {transId : int} -> unit,
      sendCancel : {transId : int} -> unit,
      replyEvt   : Net.reply event
    }

  fun proxyServer (myId, conn : conn_ops, reqEvt, initInReqs) = let
      val tbl = TransTbl.mkTable (32, Fail "TransTbl")
      val nextId = let val cnt = ref 0
            in
              fn () => let val id = !cnt in cnt := id+1; id end
            end
      fun handleMsg (IN{tid, remove, pat, replFn}) = let
            val id = nextId()
            val req = {transId = id, remove = remove, pat = pat}
            in
              TransTbl.insert tbl (tid, id, {id=id, replFn=replFn});
              #sendInReq conn req
            end
        | handleMsg (CANCEL tid) = let
            val {id, ...} = TransTbl.remove tbl tid
            in
              #sendCancel conn {transId=id}
            end
        | handleMsg (ACCEPT(tid, tsId)) = let
            val {id, ...} = TransTbl.remove tbl tid
            in
              if (tsId = myId)
                then #sendAccept conn {transId=id}
                else #sendCancel conn {transId=id}
            end
      fun handleReply {transId, vals} = (
          case TransTbl.find2 tbl transId
            of NONE => ()
            | (SOME{id, replFn}) => replFn (vals, myId)
          (* end case *))
      fun loop () = (
          select [
              wrap (reqEvt, handleMsg),
              wrap (#replyEvt conn, handleReply)
            ];
          loop ())
    in
      List.app handleMsg initInReqs;
      ignore (spawn loop)
    end

  fun mkProxyServer (myId, conn, reqEvt, initInList) = let
        val conn = {
            sendInReq  = Net.sendInReq conn,
            sendAccept = Net.sendAccept conn,
            sendCancel = Net.sendCancel conn,
            replyEvt   = Net.replyEvt conn
        }
    in
      proxyServer (myId, conn, reqEvt, initInList)
    end

  fun tupleServer tsMb = let
        val tupleTbl = TupleStore.newStore()
        fun replyIfMatch NONE = ()
          | replyIfMatch (SOME{reply, id = (_, transId), ext}) =
              reply{transId = transId, vals = ext}
        fun handleReq (Net.OutTuple t) =
              replyIfMatch (TupleStore.add (tupleTbl, t))
          | handleReq (Net.InReq{from, transId, remove, pat, reply}) =
              let
                val match = {
                      reply = reply,
                      id = (from, transId),
                      ext = pat
                }
            in
              case TupleStore.input (tupleTbl, match)
                of (SOME binds) => reply {transId=transId, vals=binds}
                | NONE => ()
              (* end case *)
            end
        | handleReq (Net.Accept{from, transId}) =
            TupleStore.remove (tupleTbl, (from, transId))
        | handleReq (Net.Cancel{from, transId}) =
            replyIfMatch(TupleStore.cancel(tupleTbl, (from, transId)))
      fun serverLoop () = (
          handleReq(Mailbox.recv tsMb);
          serverLoop ())
      in
        spawn serverLoop
      end

  fun mkTupleServer (myId, tsMb, reqEvt) = let
      val replyToProxyCh = channel()
      fun sendInReq {transId, remove, pat} =
          Mailbox.send (tsMb, Net.InReq{
              from = myId, transId = transId,
              remove = remove, pat = pat,
              reply = fn repl => send(replyToProxyCh, repl)
          })
      fun sendAccept {transId} =
          Mailbox.send (tsMb, Net.Accept{
              from = myId, transId = transId
          })
      fun sendCancel {transId} =
          Mailbox.send (tsMb, Net.Cancel{
              from = myId, transId = transId
          })
      val conn = {
          sendInReq = sendInReq,
          sendAccept = sendAccept,
          sendCancel = sendCancel,
          replyEvt = recvEvt replyToProxyCh
      }
  in
    tupleServer tsMb;
    proxyServer (myId, conn, reqEvt, [])
  end

  structure TidTbl = HashTableFn (struct
      type hash_key = thread_id
      val hashVal = hashTid
      val sameKey = sameTid
    end)

  fun mkLogServer masterPort = let
        val log = TidTbl.mkTable (16, Fail "TransactionLog")
        fun handleTrans (trans as IN{tid, ...}) =
            TidTbl.insert log (tid, trans)
        | handleTrans (CANCEL tid) =
            ignore(TidTbl.remove log tid)
        | handleTrans (ACCEPT(tid, _)) =
            ignore(TidTbl.remove log tid)
    val transEvt =
        CML.wrap(Multicast.recvEvt masterPort, handleTrans)
    fun handleGetLog () =
        (Multicast.copy masterPort, TidTbl.listItems log)
    val {call, entryEvt} = SimpleRPC.mkRPC handleGetLog
    fun serverLoop () = (
        select [entryEvt, transEvt]; serverLoop())
    in
      spawn serverLoop;
      call
    end

end

(* =========================================================================== *)
(* OutputServer: Output server thread and distribution policy *)
(* =========================================================================== *)

structure OutputServer : sig

    val spawnServer : (Tuple.tuple -> unit) -> {
            output : Tuple.tuple -> unit,
            addTS : (Tuple.tuple -> unit) -> unit
            }

    end = struct
      structure MB = Mailbox

      fun spawnServer localServer = let
            datatype msg
              = OUT of Tuple.tuple
              | ADD of (Tuple.tuple -> unit)
            val mbox = MB.mailbox()
            fun server tupleServers = let
                fun loop [] = loop tupleServers
                  | loop (next::r) = (case MB.recv mbox
                        of (OUT t) => (next t; loop r)
                        | (ADD f) => server (f::tupleServers)
                      (* end case *))
                  in
                    loop tupleServers
                  end
            in
              spawn (fn () => server [localServer]);
              { output = fn tuple => MB.send (mbox, OUT tuple),
                  addTS = fn f => MB.send (mbox, ADD f)
              }
            end

      end (* OutputServer *)

(* =========================================================================== *)
(* Linda: Client-layer interface *)
(* =========================================================================== *)

signature LINDA =
sig

  datatype val_atom
    = IVal of int
    | SVal of string
    | BVal of bool

  datatype pat_atom
    = IPat of int
    | SPat of string
    | BPat of bool
    | IFormal
    | SFormal
    | BFormal
    | Wild

  datatype 'a tuple_rep = T of (val_atom * 'a list)

  type tuple = val_atom tuple_rep
  type template = pat_atom tuple_rep

  type tuple_space

  val joinTupleSpace : {
          localPort   : int option,
          remoteHosts : string list
        } -> tuple_space

  val out   : (tuple_space * tuple) -> unit
  val inEvt : (tuple_space * template) -> val_atom list event
  val rdEvt : (tuple_space * template) -> val_atom list event

end

structure Linda : LINDA = struct
  structure MChan = Multicast
  structure SRV = TupleServer
  structure Net = Network

  datatype val_atom
    = IVal of int
    | SVal of string
    | BVal of bool

  datatype pat_atom
    = IPat of int
    | SPat of string
    | BPat of bool
    | IFormal
    | SFormal
    | BFormal
    | Wild

  datatype 'a tuple_rep = T of (val_atom * 'a list)

  type tuple = val_atom tuple_rep
  type template = pat_atom tuple_rep

  datatype tuple_space = TS of {
      request : SRV.ts_msg -> unit,
      output : Tuple.tuple -> unit
    }

  fun joinTupleSpace {localPort, remoteHosts} = let
      val reqMCh = MChan.mChannel()
      val tsReqMb = Mailbox.mailbox()
      fun out tuple = Mailbox.send(tsReqMb, Net.OutTuple tuple)
      val {output, addTS} = OutputServer.spawnServer out
      val getInReqLog = SRV.mkLogServer (MChan.port reqMCh)
      fun newRemoteTS {name, id, conn} = let
          val (port, initInReqs) = getInReqLog()
          in
              addTS (Net.sendOutTuple conn);
              SRV.mkProxyServer (
                  id, conn, MChan.recvEvt port, initInReqs)
          end
      val {myId, network, servers} = Net.initNetwork{
              port    = localPort,
              remote  = remoteHosts,
              tsReqMb = tsReqMb,
              addTS   = newRemoteTS
          }
      in
          SRV.mkTupleServer (
              myId, tsReqMb, MChan.recvEvt(MChan.port reqMCh));
          List.app newRemoteTS servers;
          TS{
              request = fn msg => MChan.multicast(reqMCh, msg),
              output = output
          }
      end

  fun doInputOp (TS{request, ...}, template, removeFlg) nack = let
        val replCh = channel ()
        fun transactionMngr () = let
            val tid = getTid()
            val replMB = Mailbox.mailbox()
            fun handleNack () = request(SRV.CANCEL tid)
            fun handleRepl (msg, tsId) = select [
                wrap (nack, handleNack),
                wrap (sendEvt(replCh, msg),
                      fn () => request(SRV.ACCEPT(tid, tsId)))
                ]
            in
              request (SRV.IN{
                  tid = tid,
                  remove = removeFlg,
                  pat = template,
                  replFn = fn x => Mailbox.send(replMB, x)
                });
              select [
                  wrap (nack, handleNack),
                  wrap (Mailbox.recvEvt replMB, handleRepl)
                ]
            end
    in
      spawn transactionMngr;
      recvEvt replCh
    end

  fun inEvt (ts, template) = withNack (doInputOp (ts, template, true))
  fun rdEvt (ts, template) = withNack (doInputOp (ts, template, false))

  fun out (TS{output, ...}, tuple) = output tuple

end

(* =========================================================================== *)
(* Example: Dining philosophers (Listing 9.2) *)
(* =========================================================================== *)

structure L = Linda

val tagCHOPSTICK = L.SVal "chopstick"
val tagTICKET = L.SVal "ticket"

fun initTS (ts, 0) = L.out (ts, L.T(tagCHOPSTICK, [L.IVal 0]))
  | initTS (ts, i) = (
      L.out (ts, L.T(tagCHOPSTICK, [L.IVal i]));
      L.out (ts, L.T(tagTICKET, [])))

fun philosopher (numPhils, hosts) = let
      val ts = L.joinTupleSpace {
            localPort   = NONE,
            remoteHosts = hosts
          }
      val philId = length hosts
      fun input x = sync(L.inEvt (ts, x))
      val left = philId and right = (philId+1) mod numPhils
      fun loop () = (
            think philId;
            input (L.T(tagTICKET, []));
            input (L.T(tagCHOPSTICK, [L.IPat left]));
            input (L.T(tagCHOPSTICK, [L.IPat right]));
            eat philId;
            L.out (ts, L.T(tagCHOPSTICK, [L.IVal left]));
            L.out (ts, L.T(tagCHOPSTICK, [L.IVal right]));
            L.out (ts, L.T(tagTICKET, []));
            loop ())
      in
        initTS(ts, philId);
        loop()
      end

(* =========================================================================== *)
(* End of CML-Linda implementation *)
(* =========================================================================== *)