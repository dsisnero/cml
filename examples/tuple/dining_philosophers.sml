(* SML/NJ CML Dining Philosophers (Chapter 9-inspired scheduling policy)
 *
 * Uses a ticket resource of size (N - 1) to prevent deadlock and per-fork
 * resources to model chopsticks. This is a pure CML implementation so it can
 * be run without tuple-space networking.
 *)

CM.make "../../smlnj/system/smlnj/smlnj-lib/smlnj-lib.cm";
CM.make "../../smlnj/libraries/cml/src/cml.cm";
CM.make "../../smlnj/libraries/cml/src/cml-lib.cm";

open CML
;

fun envInt (name, dflt) =
  (case OS.Process.getEnv name of
      NONE => dflt
    | SOME s =>
        (case Int.fromString s of
            SOME n => n
          | NONE => dflt));

val numPhils = Int.max (2, envInt ("PHILOSOPHERS", 5));
val rounds = Int.max (1, envInt ("ROUNDS", 3));

datatype req = Acquire of unit chan | Release;

fun mkCountedResource initial = let
  val reqCh : req chan = channel ()
  fun serve (count, waiters) = let
    val msg = sync (recvEvt reqCh)
  in
    case msg of
      Acquire ack =>
        if count > 0
        then (sync (sendEvt (ack, ())); serve (count - 1, waiters))
        else serve (count, waiters @ [ack])
    | Release =>
        (case waiters of
            [] => serve (count + 1, [])
          | ack::rest => (sync (sendEvt (ack, ())); serve (count, rest)))
  end
in
  spawn (fn () => serve (initial, []));
  reqCh
end;

fun acquire r = let
  val ack = channel ()
in
  sync (sendEvt (r, Acquire ack));
  sync (recvEvt ack)
end;

fun release r = sync (sendEvt (r, Release));

fun philosopher (tickets, forks, id, doneCh) = let
  val left = id
  val right = (id + 1) mod numPhils

  fun loop 0 = ()
    | loop n = (
        acquire tickets;
        acquire (Array.sub (forks, left));
        acquire (Array.sub (forks, right));
        print ("philosopher=" ^ Int.toString id ^ " round=" ^ Int.toString (rounds - n + 1) ^ " eat\n");
        release (Array.sub (forks, left));
        release (Array.sub (forks, right));
        release tickets;
        loop (n - 1))
in
  loop rounds;
  sync (sendEvt (doneCh, ()))
end;

fun main () = let
  val tickets = mkCountedResource (numPhils - 1)
  val forks = Array.tabulate (numPhils, fn _ => mkCountedResource 1)
  val doneCh = channel ()
  fun spawnAll i =
    if i = numPhils then ()
    else (spawn (fn () => philosopher (tickets, forks, i, doneCh)); spawnAll (i + 1))
  fun waitAll 0 = ()
    | waitAll n = (sync (recvEvt doneCh); waitAll (n - 1))
in
  print ("starting: philosophers=" ^ Int.toString numPhils ^ " rounds=" ^ Int.toString rounds ^ "\n");
  spawnAll 0;
  waitAll numPhils;
  print "done\n"
end;

val _ = RunCML.doit (main, SOME (Time.fromSeconds 20));
val _ = OS.Process.exit OS.Process.success;
