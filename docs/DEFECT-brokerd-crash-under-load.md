# brokerd segfaults under bulk route load

Found while measuring what a drift repair costs at scale. Not in the component
being worked on, and more serious than anything the measurement set out to
find.

## What happens

Load a few thousand routes into zebra and `brokerd` dies with SIGSEGV. Twice in
one session, at 07:52 and 07:57, both during bulk route operations.

The data plane does not crash. It is restarted — cleanly, `terminating core 1`
then `stopped core 1` then a fresh start — because brokerd is the thing feeding
it. Twenty-six start/stop events in forty minutes on the probed box.

The visible consequence is that the forwarding table empties and refills.

## Reproducer

`toolkit/vm/probe-drift-at-scale.sh`, `TOPO=ipsec`, which loads 2000 static
routes through `vtysh -f` and then bounces the FPM session. The crash reproduced
on both of its bulk phases.

```
    dataplane routes: 2008
    t+ 3s  routes 0
    t+ 6s  routes 2208
```

## What the core says

```
#0  0x00007f313456d2a9 in ?? () from /lib/x86_64-linux-gnu/libc.so.6
#2  _mid_memalign (...) at ./malloc/malloc.c:3738
#4  0x00007f31347522a0 in ?? () from /lib/x86_64-linux-gnu/libczmq.so.4
#6  zmq_close () from /lib/x86_64-linux-gnu/libzmq.so.5
```

A fault inside the allocator, reached through `zmq_close()` by way of czmq.

The stack below that is not recoverable and that is itself the finding. The
dbgsym matches the binary exactly — build ID `c2336f164d8236b6f209cb2949ced31b21c24238`
on both — and the frames still do not resolve, because they are not return
addresses. `0x5584afaa29a8` is about 11 MB past `main`, and brokerd's text is
51 KB. Those are heap addresses sitting on the stack.

So this is memory corruption rather than a null dereference, and no amount of
further gdb will recover a call chain that was overwritten. Going further needs
brokerd rebuilt under valgrind or ASAN.

Cores preserved at `build-iso/crash-tmp/` on the build host, with the matching
binary and dbgsym, since the VM is ephemeral.

## Why it matters beyond itself

It was mistaken for a property of the design. The scale probe sampled the route
count across an FPM reconnect, caught `routes 0`, and the conclusion drawn was
that an FPM resync empties the forwarding table before refilling it — which
would have made the repair primitive unusable and would have been written down
as an architectural constraint.

It is not a resync gap. It is a crash, and the empty table is a restarted data
plane. The two look identical in a route count and are entirely different
things: one is a design property to work around, the other is a defect to fix.

What separated them was one command — the age of the dataplane process. 126
seconds, on a box that had been up for hours.

## Also recorded: the measurement that proved nothing

`probe-resync-outage.sh` was written to time the window and confirm the traffic
loss. It established neither.

Its path never came up — `100% packet loss` in its own first step — so the ping
it ran across the window was aimed at an unreachable address, and the traffic
result is void. Its route samples were taken in a loop with no sleep, each
iteration costing an ssh round trip, so its `t+Ns` labels are not seconds.

It replaced an earlier check that was worse: a ping *after* the window, to an
address reached over the management interface, which is kernel-owned and never
crosses the data plane. That one reported `0% packet loss` under a heading
asking whether forwarding survived.

Both are kept as written. A probe that measured the wrong thing twice in two
different ways is worth more on the page than in memory.
