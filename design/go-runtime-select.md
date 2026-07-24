# Understanding the Go Runtime: The select Statement

By Jesús Espino • May 18, 2026 • 15 min read

Tags: #Go #Runtime #Concurrency #Channels

Source: https://internals-for-interns.com/posts/go-runtime-select/

---

In the [previous article](https://internals-for-interns.com/posts/go-runtime-slices-maps-channels/) we walked through slices, maps, and channels, and how each of them is structured under the hood. Out of those three, channels are probably the most involved one in terms of how you actually *use* them — and there's one language construct that really stands out when working with channels: the `select` statement. That's what we're going to be talking about in this post. And maybe I'm cheating a little here, because this article isn't strictly about the runtime — `select` falls in between the runtime and the compiler — but that's exactly what makes it an interesting corner of Go: it looks like a `switch`, behaves like a `switch`, and yet underneath it's a coordinated dance between the **compiler** and the **runtime**.

That coordination is the key idea I want you to take away from this post: `select` is not one feature, it's two. Half of it lives in the compiler — specifically in [`walkSelectCases`](https://github.com/golang/go/blob/go1.26.0/src/cmd/compile/internal/walk/select.go#L33) — which looks at the *shape* of your `select` and, in most common cases, rewrites it into something much simpler — often into code that has nothing to do with `select` at all. The other half lives in the runtime, in a single function called [`selectgo`](https://github.com/golang/go/blob/go1.26.0/src/runtime/select.go#L122), which only runs for the cases the compiler couldn't shortcut.

So let's split the article the same way: first we'll see all the rewrites the compiler does (and what they turn into), and then we'll dive into `selectgo` for the cases that survive.

## Half One: What the Compiler Rewrites

Before we get into the rewrites, there's one thing worth pointing out: if you look at the language spec (or just at real code), a `select` case can only ever contain one of two things — a **send** to a channel (`ch <- v`) or a **receive** from a channel (`v := <-ch`, or just `<-ch`). That's it. There's no "case `x == 5`" or "case some arbitrary expression." The compiler enforces this at compile time, which is what makes all the rewrites below possible — it knows, statically, that every case is a channel op, and it knows exactly which kind.

With that in mind: when the compiler sees a `select` statement, the first thing it does is look at how many cases you have and what kind they are. Based on that, it picks one of four strategies. Three of them avoid the runtime's `selectgo` entirely. Only the fourth — the "general case" — actually calls into it.

Let's go through them in order, from "barely a select" to "the real thing." For each, I'll show you what you wrote and what the compiler effectively turns it into.

### Case 1: The Empty Select

The simplest `select` statement you can write is an empty `select`, with no cases at all. It's the "park this goroutine forever" idiom: there's nothing to wait on, so the goroutine just blocks until the program ends. The compiler doesn't waste any cycles here — it [throws the `select` away](https://github.com/golang/go/blob/go1.26.0/src/cmd/compile/internal/walk/select.go#L38-L40) and replaces it with a single call into the runtime:

> Empty select rewrite: `select {}` becomes `runtime.block()`

That [`block`](https://github.com/golang/go/blob/go1.26.0/src/runtime/select.go#L103-L105) function just calls `gopark` with a `waitReasonSelectNoCases` reason and never returns. No channels, no cases, no algorithm. Just "go to sleep forever."

One step up the ladder, things still don't look much like a `select` at all.

### Case 2: The Single-Case Select

The next step up is a `select` with exactly one case and no `default`. If you think about it, this is just a slow way of writing a normal channel operation — there's no choice to make, no fairness question, no parking on multiple things. The compiler sees right through it and [strips the `select` away entirely](https://github.com/golang/go/blob/go1.26.0/src/cmd/compile/internal/walk/select.go#L43-L72), leaving you with the plain channel op:

> Single-case select rewrite: select with one receive case becomes a plain receive

The same idea applies to a single send case (`ch <- v` becomes a normal send) and to a single `default` case (which becomes… nothing — just the body). The compiler is essentially saying: "you didn't really need a `select` here, so I'm going to pretend you didn't write one."

Once we add a `default` into the mix, though, the rewrite stops being a pure no-op and starts to do something more useful.

### Case 3: The "One Case + Default" Select

The pattern here is "try to send (or receive), and give up if it would block" — and it's so common that the compiler has a [specialized rewrite](https://github.com/golang/go/blob/go1.26.0/src/cmd/compile/internal/walk/select.go#L100-L140) for it. Instead of building the full `select` machinery, it turns it into a plain `if/else` around a dedicated non-blocking runtime helper:

> One-case-plus-default select rewrite: select with send case and default becomes if/else around `runtime.selectnbsend`

[`selectnbsend`](https://github.com/golang/go/blob/go1.26.0/src/runtime/chan.go#L784-L786) lives in `runtime/chan.go` and is a one-liner:

```go
func selectnbsend(c *hchan, elem unsafe.Pointer) bool {
    return chansend(c, elem, false, sys.GetCallerPC())
}
```

It's just a regular channel send with an argument that says "do not block" (the third argument to `chansend`, set to `false` here). If the send can complete immediately (a receiver is waiting, or the buffer has space), it succeeds and returns `true`. Otherwise it gives up and returns `false`, and the `else` branch — your `default` — runs.

For the "try to receive" version (`case x, ok := <-ch: ...; default: ...`), the compiler emits the analogous [`selectnbrecv`](https://github.com/golang/go/blob/go1.26.0/src/runtime/chan.go#L804-L806), which returns two booleans: whether anything was selected, and whether the value came from a real send (vs. a closed channel).

What's interesting so far is what's *not* happening in any of these three cases: we never have to decide which of several paths to take, we never have to wait on multiple channels at once, we never have to coordinate with other goroutines doing their own selects. The compiler has recognized that none of that was actually needed, and reduced each of these `select`s to plain, ordinary code.

And now we get to the case that actually justifies the existence of `selectgo` in the first place.

### Case 4: The General Case

Once you have more than one real channel operation to watch, the compiler runs out of shortcuts. There's no clever rewrite that can hide the fact that we need to wait on several channels at once, so the compiler stops trying — and instead it emits a call to a single function in the runtime called `selectgo`, which is the one that, at runtime, actually knows how to do this.

But the compiler can't just emit a bare call to `selectgo` out of nowhere. `selectgo` needs to know which channels are involved, which direction each operation goes, whether there's a `default`, and a few other things. So along with the [call site](https://github.com/golang/go/blob/go1.26.0/src/cmd/compile/internal/walk/select.go#L228-L230), the compiler also emits the code that prepares all that data right before it. The easiest way to see what it has to prepare is to look at the signature of the function that's going to be called at runtime:

```go
func selectgo(
    cas0 *scase,
    order0 *uint16,
    pc0 *uintptr,
    nsends, nrecvs int,
    block bool,
) (int, bool)
```

That's a chunky-looking signature, but each parameter has a clear job. Let's walk through them in the order they show up.

The first one, `cas0`, is a pointer to the **array of cases** — what the runtime calls [`scases`](https://github.com/golang/go/blob/go1.26.0/src/runtime/select.go#L20-L23). Each entry is a tiny struct with just two fields:

```go
type scase struct {
    c    *hchan         // channel
    elem unsafe.Pointer // data element (send: source, recv: destination)
}
```

Just a channel and a pointer to the data being sent or received. Notice there's no field saying whether it's a send or a receive — and that's where the next two parameters come in. The compiler [lays out the array](https://github.com/golang/go/blob/go1.26.0/src/cmd/compile/internal/walk/select.go#L184-L195) with **all the sends first and all the receives after** (filling sends from index 0 upward and receives from the end downward in a single pass, so they meet in the middle), and then tells `selectgo` how many of each there are via `nsends` and `nrecvs`. So if an entry sits at an index below `nsends`, it's a send; otherwise, it's a receive. Direction is encoded by position, which keeps each `scase` tiny.

The second parameter, `order0`, is a scratch array twice as long as `scases`, used by the runtime to keep track of the order it's going to check the cases in and the order it's going to lock them in. The compiler doesn't fill it; it just allocates the memory and hands it over.

Then comes `block`. This is how the `default` case sneaks into the picture. `default` doesn't get its own entry in `scases`; instead, the compiler passes `block = false` when there's a `default` ("don't park me, just give up if nothing's ready") and `block = true` when there isn't ("park me until something happens").

The third parameter, `pc0`, is a little side door used only when the race detector is enabled — the compiler can optionally pass an array of program counters so the runtime can attribute synchronization events back to the right line of your code. Most of the time it's just `nil`, and you can forget it exists.

Finally, `selectgo` returns two values. `chosen` is the index of the case that won (or `-1` if the `default` fired), and `recvOK` is the `ok` value for receive cases — the same `ok` you'd get from `v, ok := <-ch`.

With all that in mind, let's see what the compiler does for a concrete example. Say you wrote:

```go
select {
case v := <-a:
    fmt.Println("a", v)
case b <- x:
    fmt.Println("b")
default:
    fmt.Println("none")
}
```

The compiler turns it into something roughly like this:

```go
chosen, recvOK := runtime.selectgo(
    [b <- x, v := <-a], // scases (sends first, then receives)
    [0, 0, 0, 0],       // order (scratch space for the runtime)
    nil,                // pc0 (race detector only)
    1,                  // nsends
    1,                  // nrecvs
    false,              // block (false because there's a default)
)

switch {
case chosen < 0:
    fmt.Println("none")    // default
case chosen == 0:
    fmt.Println("b")       // send
default:
    fmt.Println("a", v)    // recv
}
```

The piece worth dwelling on is the `switch` at the bottom. The compiler emits this dispatch code right after the `selectgo` call site, so at runtime, once `selectgo` returns, our program just looks at `chosen` and jumps to the right body. The `default` body is reached when `chosen < 0`, and the rest match the indices in the `scases` array. (Under the hood the compiler [emits a chain of `if`s](https://github.com/golang/go/blob/go1.26.0/src/cmd/compile/internal/walk/select.go#L263-L274) rather than a real `switch`/jump table, with the last case as an unconditional fall-through to save one comparison, but conceptually it's a switch on `chosen`.)

And that's the whole compiler side: three shortcuts plus one real path that builds the `scases` array, fills in the counts and the `block` flag, hands them off to `selectgo`, and dispatches on what comes back. Time to follow that real path into the runtime and see what `selectgo` actually does with all of it.

## Half Two: What the Runtime Does

The compiler has already built our binary, and now we're running what's there. Eventually, whenever our code hits a `select` statement that survived all the compiler shortcuts, it lands on the `runtime.selectgo` call that the compiler set up for us in the previous step — and here is where the magic starts.

Once `selectgo` is in charge, it needs to go through a series of steps, so let's go through them one by one.

### Poll Order: Randomized for Fairness

If `selectgo` always checked cases in source order, the first case would always win whenever multiple cases were ready. That would be a fairness disaster — a goroutine selecting on `[fastChan, slowChan]` would essentially never read from `slowChan`.

So Go [**shuffles** the poll order](https://github.com/golang/go/blob/go1.26.0/src/runtime/select.go#L167-L195) on every call. The runtime writes a random permutation of the case indices into the first half of that `order` array we mentioned earlier, and that's what it'll walk when it's time to check the cases.

This is the only formal guarantee `select` gives you about fairness: when multiple cases are simultaneously ready, the choice is uniformly random.

The poll order is what `selectgo` uses to *inspect* the cases, but before it can inspect anything it needs to safely take the channels' locks — and that's a separate problem with its own ordering.

### Lock Order: Sorted by Channel Address

Before `selectgo` can actually start looking at the cases, it has to acquire `c.lock` on every channel involved. You can't safely look at a channel's internal state without it.

But locking multiple channels at once is a classic deadlock recipe. Picture two goroutines:

- Goroutine A: `select { case <-ch1: ...; case <-ch2: ... }`
- Goroutine B: `select { case <-ch2: ...; case <-ch1: ... }`

If A grabs `ch1`'s lock and B grabs `ch2`'s lock at the same moment, each is now waiting for the other. Classic deadlock.

The fix is the standard one: define a **global total order** on locks, and always acquire them in that order. Go [uses the channel's memory address](https://github.com/golang/go/blob/go1.26.0/src/runtime/select.go#L545-L547) (`uintptr` of the `*hchan`) as the [sort key](https://github.com/golang/go/blob/go1.26.0/src/runtime/select.go#L206-L240). Any two goroutines selecting on the same channels will compute the same order, so they can't deadlock against each other.

With the locks safely held and the poll order shuffled, the real work begins.

### Pass 1: Look for an Immediately-Ready Case

With all the locks held, `selectgo` [walks the cases](https://github.com/golang/go/blob/go1.26.0/src/runtime/select.go#L264-L301) in **poll order** (the random one — *not* the lock order) and asks each case: "can you proceed right now?"

For a **receive** case, the answer is yes if there's already a sender waiting on the other end of the channel, or if the channel is buffered and has data sitting in the buffer, or if the channel has [been closed](https://github.com/golang/go/blob/go1.26.0/src/runtime/select.go#L504-L514) (in which case the receive immediately yields the zero value with `recvOK = false`).

For a **send** case, the answer is yes if there's already a receiver waiting, or if the channel is buffered and has room in the buffer. There's also a third possibility worth calling out: if the channel is closed, the send doesn't quietly fail or get skipped — it [`panic`s](https://github.com/golang/go/blob/go1.26.0/src/runtime/select.go#L539-L542), exactly like a plain `ch <- v` would. There's no way to "select around" a send on a closed channel.

As soon as `selectgo` finds a case that can proceed, it performs the channel operation, releases all the locks, and returns the case's index. Done.

If nothing is ready and `block == false` (the source had a `default`), it [releases the locks and returns `-1`](https://github.com/golang/go/blob/go1.26.0/src/runtime/select.go#L303-L307), which the compiler-emitted dispatcher interprets as "run the default body."

If nothing is ready and `block == true`, we go to pass 2.

### Pass 2: Enqueue on Every Channel, Then Park

This is where `select` does something genuinely unusual. The goroutine needs to wait on several channels at the same time, so that *any* of them can wake it up. So the runtime [goes through each case and registers our goroutine as a waiter](https://github.com/golang/go/blob/go1.26.0/src/runtime/select.go#L309-L351) on that channel — exactly like what would happen with a plain blocking send or receive, except we're doing it on *every* channel at once.

If you have four cases, your goroutine is now sitting in four different channels' wait lines simultaneously. Whichever one fires first wins.

Once we're registered on every channel, the runtime parks the goroutine and releases all the channel locks.

At this point, our goroutine is off the run queue, sitting idle, waiting for somebody to ring one of those four bells.

Sooner or later, somebody on the other end of one of those channels is going to notice us — and that's when pass 3 kicks in.

### Pass 3: Wake Up and Clean Up

Eventually some other goroutine on the other end of one of our channels does its thing — sends a value, receives one, or closes the channel — and notices that we're the one waiting for it. It completes the data transfer for us (so by the time we wake up, the value has already been moved into or out of the right variable), records *which* of our cases won, and marks our goroutine as runnable again.

When we wake up back inside `selectgo`, we're not quite done yet. Remember, we registered ourselves on every channel, but only one of them actually fired — the rest still have us listed as a waiter, and if we leave it that way, somebody else trying to use those channels would eventually trip over our stale registration. So before returning, we re-lock all the channels and [quickly walk through our list of registrations](https://github.com/golang/go/blob/go1.26.0/src/runtime/select.go#L360-L401), removing every losing one from its channel's wait line. For the winning one we just remember its index, so we can tell the caller which case fired.

With cleanup done, we return `chosen` and `recvOK`. Back in the compiler-emitted code, the `switch` on `chosen` jumps to the right body, and life goes on.

## Summary

`select` is a nice example of the compiler and runtime splitting work between them. The compiler rewrites the easy shapes away — empty, single-case, and `{case, default}` — so they never go through the full `selectgo` machinery. Only the general case actually calls `selectgo`, and even then the compiler does the bookkeeping: it lays out the `scases` array, hands over the counts and the `block` flag, and dispatches on the returned `chosen` with a `switch`.

`selectgo` itself shuffles a **random poll order** for fairness, builds a **deadlock-free lock order** by sorting channels by their memory address, and locks them all. It looks for any case that can complete right now; if one does, it runs and returns. If not, it registers our goroutine on every channel at once, parks it, and waits for someone on the other end to wake us up — then cleans up the registrations on the channels that didn't fire and returns the winning case's index.

If you want to read the source, [`src/runtime/select.go`](https://github.com/golang/go/blob/go1.26.0/src/runtime/select.go) and [`src/cmd/compile/internal/walk/select.go`](https://github.com/golang/go/blob/go1.26.0/src/cmd/compile/internal/walk/select.go) are both short and very readable once you have the structure above in mind.
