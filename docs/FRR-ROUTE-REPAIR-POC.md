# Route-level repair on FRR 10.3: proof of concept

What this answers: **can FRR safely replay one route?** It does not answer
whether DANOS should carry an FRR patch to get it. Those are separate
questions and the second one is left open on purpose.

## Result

| | |
|---|---|
| FRR | Debian's 10.3, which is what the image installs |
| Patch | `frr-poc/0001-fpm-replay-one-route.patch` |
| Size | 151 lines, one file |
| Build | complete FRR build, 0 errors, 0 warnings |
| CLI | clippy accepts the DEFPY; the command works at runtime |
| P1 — scope on a present route | **6/6** |
| P2 — repair of a genuinely missing route | **7/7** |

The claim the evidence supports, and no more than this:

> FRR 10.3 can provide a route-level replay primitive for a route that zebra
> has installed. It replays exactly one route through the existing FPM path,
> without restarting the FPM session, without restarting the data plane, and
> without a full RIB walk.

## What the patch is

Almost all extraction. `fpm_rib_send()`'s reconnect walk already regenerates a
route's FPM message from `dest->selected_fib`; its loop body becomes
`fpm_rib_send_one()` and both paths call it. A repair that encoded routes its
own way would program a route into a state the next reconnect disagrees with,
so there is one encoder, not two.

`fpm_rib_replay_one()` adds what did not exist: naming one destination.
`srcdest_rnode_lookup()` rather than `_get()` -- `_get` creates the node when
it is absent, and repairing a prefix the RIB does not have must fail rather
than conjure an empty one. It returns named errors (`ENOTCONN`, `ENOENT`,
`ESRCH`, `ENODATA`, `ENOBUFS`), because a reconciliation loop cannot act on
"it did not work".

There is no new state anywhere. brokerd is untouched and remains a stateless
coalescing deliverer; the source of truth is zebra's `selected_fib`, which it
already maintains and already encodes from on every reconnect.

### Concurrency

The reason the primitive is small rather than delicate. `fpm_rib_send` is
scheduled on `zrouter.master`, which owns the RIB, while the socket work runs
on the FPM's own pthread; `fpm_nl_enqueue()` takes `obuf_mutex` and is safe
from either. zebra has no separate CLI thread -- `frr_init()` returns one event
loop, `main.c` assigns it to `zrouter.master`, `vty_init()` points `vty_master`
at the same one -- so the command looks up, encodes and enqueues synchronously,
holding the route node's reference throughout. No `rib_dest` crosses a thread
boundary, which rules out the failure this design would otherwise be about:
look up, release, let a protocol replace the route, encode from freed memory.

## P1: what the primitive's scope is

`probe-replay-one-scope.sh`, on a route present on both sides:

```
broker messages   21 -> 22  (+1)
dataplane pid     7316 -> 7316
dataplane routes  8 -> 8
fpm closes        1 -> 1
```

The number carrying the argument is `+1`, and it carries it because of where it
comes from: brokerd's own `processed_msg`, counted on the **receiving** side of
the FPM socket. It is not a number the patch produces, computes or can
influence. An implementation that quietly ran `fpm_rib_reset()` and a full
`fpm_rib_send()` would move it by the size of the table.

`show fpm counters` bytes are recorded as corroboration only. Bytes are an
encoding length, not a message count: they move with address family, next-hop
count and attributes, so they cannot answer "how many routes".

## P2: whether it repairs

P1 could not test repair, because nothing in this system could make a route go
missing without also fixing it. The only lever was an FPM session bounce, and a
bounce runs the full RIB walk -- which would perform the repair before the
primitive was called.

So the loss is injected on the wire, by `fpm-filter.py` between zebra and
brokerd:

```
zebra --(2621)--> fpm-filter --(2620)--> brokerd --> dataplane
```

brokerd is not modified and still listens on 2620; zebra is redirected by
configuration. The route is lost the way a delivery failure loses one -- sent
by zebra, never received by brokerd -- rather than by a component being taught
to pretend. `probe-replay-one-repair.sh`:

```
fpm-filter: dropped 10.91.9.0/24

    RIB           present
    data plane    absent
    pid           11379

fpm route-replay 10.91.9.0/24

    RIB           present
    data plane    present
    pid           11379
    broker msgs   +1
    routes        10 -> 11
    fpm closes    3 -> 3
```

### The pid is the assertion that matters

This project already had a recovery path that ends with the route present:
brokerd crashes, systemd restarts it, `broker_dump_routes()` re-seeds the whole
table from the kernel FIB. It was written up once as a repair primitive, "20 of
20 routes restored", on exactly the evidence of the routes being back.

That path changes the data plane's pid. This one does not.

**So the finding is not only that repair works. It is that route-level repair
and session-level recovery are different primitives, and this is the first
evidence in this project that tells them apart.** Everything before it could
only show that restarting and re-seeding restores forwarding state.

## `fpm-filter.py` is a test instrument

Fault injection, not a repair mechanism, and it has no place on a production
forwarding path. It exists to make one FPM delivery failure reproducible, and
it is in `toolkit/vm/` for that reason and no other.

Its netlink parser was checked offline before it was trusted: it names IPv4,
IPv6 and default-route prefixes correctly, and returns "I cannot read this"
rather than a wrong prefix for non-route and truncated messages. A parser that
answers confidently and wrongly would drop the wrong message, and the test
would still look like it worked.

## Cost

Not "the patch is small, therefore cheap". The code surface is small; the
build and version surface is real.

1. The downstream patch is 151 lines in one file.
2. **The DANOS build container cannot build FRR 10.3 at all.** It carries this
   project's own libyang 1.0.184 against FRR's requirement of 2.1.128. The PoC
   was built in a clean Debian 13 container.
3. So maintaining the patch means maintaining that second build environment.
4. Every FRR version bump is a full FRR build, not a single-file compile:
   building `zebra/zebra` alone fails on generated protobuf headers.
5. And a rebase is not done when the patch applies. P1 and P2 have to be re-run,
   because the patch depends on zebra's internal RIB and FPM structures --
   `rib_dest_t`, `selected_fib`, `RIB_DEST_UPDATE_FPM`, the thread split -- any
   of which upstream may reorganise without breaking the patch's application.
6. Upstream FRR has no equivalent command. `dplane_fpm_nl` installs six, none
   of them a replay. The mechanism is implemented and simply not exposed as a
   per-object primitive.

## Three conclusions

**1. The primitive: yes.** Safe, single-route, no session restart, no data
plane restart. P1, 6/6.

**2. Actual repair: yes.** Delivery-loss drift, RIB authoritative, single-route
replay, data plane repaired without a restart. P2, 7/7.

**3. The architecture decision: open.**

```
                 ┌─ maintain a downstream FRR patch
                 │
route repair ────┤
                 │
                 └─ build reconciliation into the DANOS/DPA architecture
```

This document does not choose. It establishes that the first branch works and
what it costs to keep, so that the comparison can be made against something
measured rather than assumed. The second branch has not been costed at all, and
costing it means confronting desired state, ownership, ordering, withdrawal,
VRFs, next-hop dependency, route replacement and restart recovery -- none of
which this PoC needed, and all of which a native reconciliation layer would.

## Reproducing

Needs the patched module installed by hand, brokerd started with `-d` for its
message counter, a vty password on zebra (vtysh rejects the command from its
own compiled-in table before it reaches zebra), and `fpm-filter.py` on the box.

```
toolkit/vm/probe-replay-one-scope.sh     # P1
toolkit/vm/probe-replay-one-repair.sh    # P2
```

Nothing here is in any image. The patch is a file in this repository; the
module, the filter and the brokerd debug flag were applied by hand to an
ephemeral VM.
