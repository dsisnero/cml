use "examples/tuple/load.sml";

fun assertVals (got, expect, msg) =
  if got = expect then () else raise Fail msg

fun testMain () = let
  val ts = Linda.joinTupleSpace {localPort = NONE, remoteHosts = []}

  val _ = Linda.out (ts, Linda.T (Linda.SVal "num", [Linda.IVal 42]))
  val got1 = CML.sync (Linda.inEvt (ts, Linda.T (Linda.SVal "num", [Linda.IFormal])))
  val _ = assertVals (got1, [Linda.IVal 42], "inEvt binding mismatch")

  val _ = Linda.out (ts, Linda.T (Linda.SVal "peek", [Linda.IVal 9]))
  val got2 = CML.sync (Linda.rdEvt (ts, Linda.T (Linda.SVal "peek", [Linda.IFormal])))
  val _ = assertVals (got2, [Linda.IVal 9], "rdEvt binding mismatch")

  val got3 = CML.sync (Linda.inEvt (ts, Linda.T (Linda.SVal "peek", [Linda.IFormal])))
  val _ = assertVals (got3, [Linda.IVal 9], "rdEvt did not preserve tuple")
in
  print "tuple smoke test passed\n"
end

val status = RunCML.doit (testMain, SOME (Time.fromSeconds 5));
val _ = OS.Process.exit status;
