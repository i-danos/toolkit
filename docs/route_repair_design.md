# A route-level repair primitive

Design only. No code has been changed, and the reconnaissance behind it was
read-only.

The question this answers: drift detection works, and there is nothing safe to
do about what it detects. The only repair action available is an FPM session
bounce, which blanks the forwarding table -- measured on the built image, three
bounces out of three, with the data plane replaced every time and no coredump.
So detection exists and repair does not.

## 1. The path a route takes today

```
 zebra RIB
    │  dest->selected_fib
    ▼
 zebra dplane  ──enqueue──▶  dplane_fpm_nl (provider)
                                  │  fpm_nl_enqueue()
                                  ▼
                            FPM netlink, TCP :2620
                                  │
                                  ▼
                              brokerd  ──ZMQ PUSH──▶  dataplane
```

Steady state is purely event-driven. `fpm_nl_process()` dequeues contexts the
zebra dataplane hands it -- route install, update, delete -- and queues them for
the socket. Nothing re-sends a route that is already installed. The module says
so itself, in the branch taken when there is no connection:

```c
/* Skip all notifications if not connected, we'll walk the RIB anyway. */
```

DANOS runs `dplane_fpm_nl`, not the older `zebra_fpm`. `daemons.danos` has
`zebra_options="... -M dplane_fpm_nl"`, and `fpm address` -- the command every
bounce in this project has used -- is defined in `dplane_fpm_nl.c`. The
distinction is not cosmetic: `RIB_DEST_UPDATE_FPM` is steady-state bookkeeping
in the old module and is used **only** by the reconnect walk in this one.

The FRR being read is Debian's 10.3, which is what the image installs. The
`frr` repository in this tree is `7.6-0danos1` and is not what runs.

## 2. The replay that already exists

On reconnect, `fpm_process_event(FNE_RECONNECT)` starts a chain of walks --
LSPs, next-hop groups, the RIB, then RMACs. The RIB half is two events:

```
 fpm_rib_reset()   clears RIB_DEST_UPDATE_FPM on every destination
        │
        ▼
 fpm_rib_send()    walks every table, every node, and sends the ones not flagged
```

The body of that walk is already a complete single-route regeneration:

```c
dplane_ctx_reset(ctx);
dplane_ctx_route_init(ctx, DPLANE_OP_ROUTE_INSTALL, rn, dest->selected_fib);
if (fpm_nl_enqueue(fnc, ctx) == -1)
        /* retry later */;
SET_FLAG(dest->flags, RIB_DEST_UPDATE_FPM);
```

Nothing in it is specific to being inside a loop. What is missing is a way to
name one destination.

## 3. The primitive

Extract the loop body, unchanged:

```c
static int fpm_rib_send_one(struct fpm_nl_ctx *fnc,
                            struct zebra_dplane_ctx *ctx,
                            struct route_node *rn,
                            rib_dest_t *dest);
```

`fpm_rib_send()` then calls it per node and keeps its own retry and flag
handling; the new entry point calls it once. The regeneration logic exists in
exactly one place either way, which is the point of extracting rather than
copying: a repair that drifts from the reconnect walk would repair a route into
a state the next reconnect disagrees with.

## 4. Where the caller comes from

`rib_find_rn_from_ctx()` already shows the lookup chain, and its own doc comment
carries the contract that matters:

```c
/*
 * Note well: the route-node is returned with a ref held -
 * route_unlock_node() must be called eventually.
 */
table = zebra_vrf_lookup_table_with_table_id(afi, safi, vrf, tableid);
rn    = srcdest_rnode_get(table, dest_pfx, src_pfx);
```

A repair wants `srcdest_rnode_lookup()` rather than `_get()`: `_get` creates the
node when it is absent, and "repair a prefix that does not exist" must fail, not
conjure an empty destination.

## 5. Concurrency and lifetime

This is the part that decides the shape, and the answer is better than expected.

The module runs on two threads and the split is explicit in how each piece is
scheduled:

| Runs on | What |
|---|---|
| `zrouter.master` (zebra main, the RIB owner) | `fpm_rib_reset`, `fpm_rib_send`, `fpm_nhg_send` |
| `fnc->fthread->master` (the FPM's own pthread) | `fpm_connect`, `fpm_process_queue`, `fpm_process_event` |

So the existing RIB walk already runs on the thread that owns the RIB, which is
why it touches `route_node` and `rib_dest` without taking anything. The module
schedules *into* `zrouter.master` when it needs RIB work, from the FPM thread:

```c
event_add_timer(zrouter.master, fpm_rib_reset, fnc, 0, &fnc->t_ribreset);
```

`fpm_nl_enqueue()` is callable from either thread: it takes `fnc->obuf_mutex`
before touching the output stream, which is why the walk on the main thread and
the queue processor on the FPM thread can both feed the socket.

That gives the primitive a shape with no lifetime problem in it:

```
zrouter.master, synchronously, start to finish
 ├── look up table by (afi, safi, vrf, tableid)
 ├── srcdest_rnode_lookup()          -> rn, with a ref held
 ├── dest = rib_dest_from_rnode(rn)
 ├── if (!dest || !dest->selected_fib) -> fail, unlock, return
 ├── fpm_rib_send_one(fnc, ctx, rn, dest)   [ enqueue locks obuf_mutex ]
 └── route_unlock_node(rn)
```

No `struct rib_dest *` is handed to another thread, and the reference is held
across the whole of it. The failure the shape rules out is the one worth naming:
look up the destination, release, let BGP replace the route, then encode from a
pointer to freed memory.

**The CLI entry point must therefore not follow the pattern the other commands
in this module use.** `fpm address` ends with

```c
event_add_event(gfnc->fthread->master, fpm_process_event, gfnc, FNE_RECONNECT, ...);
```

-- it hands an event code to the FPM thread, which is right for a command whose
work is socket work. A replay's work is RIB work, so it belongs on
`zrouter.master`.

It already is. `frr_init()` returns the one event loop, `zebra/main.c` assigns
it to `zrouter.master` and passes it to `frr_run()`, and `vty_init(master, ...)`
in `lib/libfrr.c` points `vty_master` at the same loop. There is no separate CLI
thread in zebra, so a vty command executes on the thread that owns the RIB and
can do the lookup, the encode and the enqueue synchronously where it stands.

That is what makes the primitive small. Were it otherwise, the command would
have to marshal a prefix -- never a `rib_dest *` -- onto `zrouter.master` and
answer the operator before the work had happened.

## 6. Failure semantics

A repair that cannot say why it did nothing is not usable by a reconciliation
loop, so each case is distinct:

| Case | Answer |
|---|---|
| No FPM connection | refuse; the reconnect walk would resend everything anyway |
| Table not found (bad vrf/tableid) | refuse, naming which |
| Prefix not in the RIB | refuse -- "nothing to repair" is not success |
| `dest->selected_fib == NULL` | refuse -- zebra has the prefix but nothing installed |
| `fpm_nl_enqueue()` returns -1 | the output buffer is full; report back-pressure, do not retry silently |
| enqueued | success means *handed to the socket*, not *programmed* |

The last line is the important one. The primitive's success says the message was
queued to brokerd. Whether the data plane ends up holding the route is a
separate question, and the thing that answers it already exists: `dpa-drift.py`
compares zebra's RIB against the DPA object view. Repair and verification stay
separate on purpose.

## 7. Relationship to the session bounce

The bounce stays. It is the only thing that recovers from a desynchronised
*session*, and it does more than routes -- LSPs, next-hop groups, RMACs.

What changes is that it stops being the answer to "one route is missing". The
two differ in blast radius, and that is the whole point:

| | session bounce | replay one |
|---|---|---|
| forwarding table | blanked, 3/3 measured | untouched |
| data plane process | replaced, 3/3 measured | untouched |
| brokerd | exits and is restarted | unaffected |
| scope | every object of every kind | one prefix |

## 8. What this does not do

It adds no state anywhere. brokerd stays a stateless coalescing deliverer --
its hash is a queue, not a cache, and `rib_route_delete()` removes each entry on
delivery. The source of truth for the repair is `dest->selected_fib`, which
zebra already maintains and already uses for exactly this encoding on every
reconnect.

That is deliberate. The alternative -- teaching brokerd what a route should be
-- would put a second routing state in the one component built to have none, and
would duplicate what the DPA's Desired/Programmed model is for. The eventual
architecture reconciles DPA state against backends; this primitive is the
smallest thing that makes repair possible before that exists, and it does not
have to be unbuilt to get there.

## 9. Testing

The suite has to distinguish repair from restart, because this project has
already confused the two once: an FPM reconnect was recorded as a repair
primitive, "20 of 20 routes restored", when what happened was brokerd crashing,
systemd restarting it, and `broker_dump_routes()` re-seeding the whole table
from the kernel FIB. The routes did arrive. The mechanism was not the one named.

So the test asserts the negative as carefully as the positive:

1. establish drift for one prefix (break the session, add the route, restore)
2. `dpa-drift.py` reports exactly that prefix missing
3. replay that one prefix
4. drift clears
5. **the data plane's pid is unchanged** -- otherwise this is a restart wearing a repair's name
6. **no brokerd coredump** -- same reason
7. the other routes' counts are unchanged -- the repair was not a bulk resync
8. replaying a prefix that is not in the RIB fails, and says so

`probe-bounce-blanks-table.sh` already asserts on the pid across a bounce and can
lend its shape to 5 and 6.

## 10. Cost not yet counted

This is a patch to Debian's FRR, not to a DANOS package. That is a new
maintenance surface: the patch has to follow FRR versions, and every FRR update
in Debian becomes a rebase. Nothing in this document argues that cost is worth
paying -- it establishes only that the change itself is small, that it needs no
new state, and that its shape has no lifetime hazard in it.

Upstream has no equivalent command. `dplane_fpm_nl` installs six: `fpm address`,
`fpm use-next-hop-groups`, `fpm use-route-replace`, `clear fpm counters`,
`show fpm status`, `show fpm counters`. The mechanism for replay is implemented
and not exposed as a per-object primitive, which is what makes this a small
patch rather than a feature.
