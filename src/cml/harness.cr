# CML Harnesses — Split/Combine Application Harnesses
#
# Translation of the harnesses described in:
#   "Prototyping Application Models in Concurrent ML"
#   Johnston, Fleury, Downton (2003)
#
# Section 3: CML Examples (building blocks)
# Section 4: Split/Combine Application Harness (five stages)

require "../cml"

module CML
  module Harness
    # =====================================================================
    # Section 3.2 — Event-Based Remote Procedure Call
    # =====================================================================
    #
    # SML:
    #   fun rpc_server(ch, f, arg) = sync(sendEvt(ch, f(arg)));
    #   fun rpc_client f arg = let val ch = channel();
    #                               val tid = spawnc rpc_server (ch, f, arg);
    #                          in recvEvt(ch) end;
    #
    # The key insight: rpc_client returns an *event*, not a value.
    # The caller must sync on the returned event to get the result.

    # Server: apply function to argument, send result on channel
    def self.rpc_server(ch : CML::Chan(O), f : Proc(I, O), arg : I) : Nil forall I, O
      CML.sync(ch.send_evt(f.call(arg)))
    end

    # Client: create channel, spawn server fiber, return receive event
    # Returns Event(O) — the caller must CML.sync(evt) to get the value
    def self.rpc_client(f : Proc(I, O), arg : I) : CML::Event(O) forall I, O
      ch = CML::Chan(O).new
      CML.spawn do
        rpc_server(ch, f, arg)
      end
      ch.recv_evt
    end

    # =====================================================================
    # Section 3.3 — Timeout via guard + atTimeEvt
    # =====================================================================
    #
    # SML:
    #   fun timeout t = guard (fn () => atTimeEvt (Time.+ (t, Time.now())));
    #
    # The guard defers time evaluation until sync time, ensuring exactly
    # the specified duration from sync, not from timeout_evt construction.
    # Note: CML.timeout(duration) has the same semantics using Blocked.

    def self.timeout_evt(duration : Time::Span) : CML::Event(Nil)
      CML.guard do
        target = Time.utc + duration
        CML.at_time(target)
      end
    end

    # =====================================================================
    # Section 4.1 — Serial Hierarchical Harness (SH)
    # =====================================================================
    #
    # SML:
    #   fun SH_harness (depth, max_depth) (f, split) input =
    #     if (depth < max_depth)
    #     then let val (combine, input1, input2) = split input;
    #              val daughter = SH_harness (depth+1, max_depth) (f, split);
    #              val output1 = daughter input1;
    #              val output2 = daughter input2;
    #          in combine output1 output2 end
    #     else f input;
    #
    # Serial recursive divide-and-conquer. Both sub-problems are solved
    # sequentially in the same fiber.

    def self.sh_harness(*, depth : Int32, max_depth : Int32,
                        f : Proc(I, O), split : Proc(I, {Proc(O, O, O), I, I}),
                        input : I) : O forall I, O
      if depth < max_depth
        combine, input1, input2 = split.call(input)
        daughter = ->(inp : I) : O { sh_harness(depth: depth + 1, max_depth: max_depth, f: f, split: split, input: inp) }
        output1 = daughter.call(input1)
        output2 = daughter.call(input2)
        combine.call(output1, output2)
      else
        f.call(input)
      end
    end

    # =====================================================================
    # Section 4.2 — Communicating Parallel Hierarchical Harness (CPH)
    # =====================================================================
    #
    # SML:
    #   fun CPH_harness (depth, max_depth) (f, split) ch input =
    #     if (depth < max_depth)
    #     then let val ch1 = channel(); val ch2 = channel();
    #              val (combine, input1, input2) = split input;
    #              val daughter = CPH_harness (depth+1, max_depth) (f, split);
    #              val _ = spawnc (daughter ch1) input1;
    #              val _ = spawnc (daughter ch2) input2;
    #              val output1 = recv(ch1);
    #              val output2 = recv(ch2);
    #          in send(ch, combine output1 output2) end
    #     else send(ch, f input);
    #
    # Channel-based parallel split/combine. Sub-harnesses run in separate
    # fibers and communicate results via channels.

    def self.cph_harness(*, depth : Int32, max_depth : Int32,
                         f : Proc(I, O), split : Proc(I, {Proc(O, O, O), I, I}),
                         ch : CML::Chan(O), input : I) : Nil forall I, O
      if depth < max_depth
        ch1 = CML::Chan(O).new
        ch2 = CML::Chan(O).new
        combine, input1, input2 = split.call(input)

        CML.spawn do
          cph_harness(depth: depth + 1, max_depth: max_depth, f: f, split: split, ch: ch1, input: input1)
        end
        CML.spawn do
          cph_harness(depth: depth + 1, max_depth: max_depth, f: f, split: split, ch: ch2, input: input2)
        end

        output1 = ch1.recv
        output2 = ch2.recv
        ch.send(combine.call(output1, output2))
      else
        ch.send(f.call(input))
      end
    end

    # =====================================================================
    # Section 4.3 — Event-Explicit Parallel Hierarchical Harness (EEPH)
    # =====================================================================
    #
    # SML:
    #   fun EEPH_harness (depth, max_depth) (f, split) input =
    #     if (depth < max_depth)
    #     then let val (combine, input1, input2) = split input;
    #              val daughter = EEPH_harness (depth+1, max_depth) (f, split);
    #              val event1 = rpc_client daughter input1;
    #              val event2 = rpc_client daughter input2;
    #              val output1 = sync(event1);
    #              val output2 = sync(event2);
    #          in combine output1 output2 end
    #     else f input;
    #
    # Event-explicit parallel version. Uses rpc_client/event to spawn
    # sub-harnesses, then explicitly syncs each event to collect results.
    # Less channel management than CPH — channels are hidden in rpc_client.
    #
    # Note: EEPH daughter returns O (not Event(O)), so rpc_client works directly.

    def self.eeph_harness(*, depth : Int32, max_depth : Int32,
                          f : Proc(I, O), split : Proc(I, {Proc(O, O, O), I, I}),
                          input : I) : O forall I, O
      if depth < max_depth
        combine, input1, input2 = split.call(input)
        daughter = ->(inp : I) : O { eeph_harness(depth: depth + 1, max_depth: max_depth, f: f, split: split, input: inp) }

        event1 = rpc_client(daughter, input1)
        event2 = rpc_client(daughter, input2)

        output1 = CML.sync(event1)
        output2 = CML.sync(event2)

        combine.call(output1, output2)
      else
        f.call(input)
      end
    end

    # =====================================================================
    # Section 4.4 — Event-Implicit Parallel Hierarchical Harness (EIPH)
    # =====================================================================
    #
    # SML:
    #   fun event_and combine event1 event2 =
    #     let val event1' = rpc_client sync event1;
    #         val event2' = rpc_client sync event2;
    #     in guard (fn () => alwaysEvt (combine (sync event1') (sync event2'))) end;
    #
    #   fun EIPH_harness (depth, max_depth) (f, split) input =
    #     if (depth < max_depth)
    #     then let val (combine, input1, input2) = split input;
    #              val daughter = EIPH_harness (depth+1, max_depth) (f, split);
    #              val event1 = rpc_client daughter input1;
    #              val event2 = rpc_client daughter input2;
    #          in event_and combine event1 event2 end
    #     else alwaysEvt(f input);
    #
    # The "event-implicit" approach: the harness deals purely in events.
    # Synchronization is deferred to the last possible moment via guard.
    # Sub-harnesses are spawned in fibers; results flow back via IVar.
    # event_and spawns sync fibers eagerly, but collects results lazily.

    # RPC client variant for functions that return events.
    # Spawns a fiber that calls f(arg), syncs the resulting event,
    # and sends the unwrapped value on a channel.
    # Returns Event(O) — an event that fires with the unwrapped result.
    def self.rpc_client_evt(f : Proc(I, CML::Event(O)), arg : I) : CML::Event(O) forall I, O
      ch = CML::Chan(O).new
      CML.spawn do
        evt = f.call(arg)
        result = CML.sync(evt)
        CML.sync(ch.send_evt(result))
      end
      ch.recv_evt
    end

    # Combine two events using a binary combine function.
    # Eagerly spawns fibers to sync each event (so they run in parallel),
    # then lazily collects results via a guard event.
    def self.event_and(combine : Proc(O, O, O), event1 : CML::Event(O), event2 : CML::Event(O)) : CML::Event(O) forall O
      # Eagerly spawn fibers to sync each event; store results in IVars
      iv1 = CML::IVar(O).new
      iv2 = CML::IVar(O).new

      CML.spawn { iv1.i_put(CML.sync(event1)) }
      CML.spawn { iv2.i_put(CML.sync(event2)) }

      # Guard defers combining until the last possible moment
      CML.guard do
        val1 = iv1.i_get
        val2 = iv2.i_get
        CML.always(combine.call(val1, val2))
      end
    end

    # EIPH harness: returns an Event(O).
    # Sub-harnesses return events, so use rpc_client_evt to spawn them
    # in fibers and unwrap the event layer.
    def self.eiph_harness(*, depth : Int32, max_depth : Int32,
                          f : Proc(I, O), split : Proc(I, {Proc(O, O, O), I, I}),
                          input : I) : CML::Event(O) forall I, O
      if depth < max_depth
        combine, input1, input2 = split.call(input)
        daughter = ->(inp : I) : CML::Event(O) { eiph_harness(depth: depth + 1, max_depth: max_depth, f: f, split: split, input: inp) }

        event1 = rpc_client_evt(daughter, input1)
        event2 = rpc_client_evt(daughter, input2)

        event_and(combine, event1, event2)
      else
        CML.always(f.call(input))
      end
    end

    # =====================================================================
    # Section 4.5 — Unified Harness (U)
    # =====================================================================
    #
    # SML:
    #   fun U_harness (exec, merge_using, return) (depth, max_depth) (f, split) input =
    #     if (depth < max_depth)
    #     then let val (combine, input1, input2) = split input;
    #              val daughter = U_harness (...) (depth+1, max_depth) (f, split);
    #              val output1 = exec daughter input1;
    #              val output2 = exec daughter input2;
    #          in merge_using combine output1 output2 end
    #     else return (f input);
    #
    #   val id = fn a => a;
    #   val SH_harness   = U_harness (id,        id,        id);
    #   val EIPH_harness = U_harness (rpc_client, event_and, alwaysEvt);
    #
    # The unified harness abstracts over three higher-order functions:
    #   exec        : how to invoke a sub-harness (direct call vs RPC)
    #   merge_using : how to combine two results (direct vs event_and)
    #   return_val  : how to wrap a leaf result (identity vs alwaysEvt)

    # exec         : (daughter_fn, input) -> R  (how to invoke sub-harness)
    # merge_using  : (combine, result1, result2) -> R  (how to combine)
    # return_val   : O -> R  (how to wrap a leaf result)
    # Types are inferred by Crystal's type checker from usage.
    def self.u_harness(*, exec, merge_using,
                       return_val : Proc(O, R),
                       depth : Int32, max_depth : Int32,
                       f : Proc(I, O), split : Proc(I, {Proc(O, O, O), I, I}),
                       input : I) : R forall I, O, R
      if depth < max_depth
        combine, input1, input2 = split.call(input)
        daughter = ->(inp : I) : R { u_harness(exec: exec, merge_using: merge_using, return_val: return_val, depth: depth + 1, max_depth: max_depth, f: f, split: split, input: inp) }

        output1 = exec.call(daughter, input1)
        output2 = exec.call(daughter, input2)

        merge_using.call(combine, output1, output2)
      else
        return_val.call(f.call(input))
      end
    end

  end
end
