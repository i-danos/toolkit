# Route repair: decision material

Evidence for a decision that has not been made. This document does not
recommend an option, and where the two sides are known to different depths it
says so rather than levelling them.

Sources: `FRR-ROUTE-REPAIR-POC.md` (measured), `route_repair_design.md`
(read-only analysis), and four constraint findings recorded below from source
inspection with runtime confirmation.

## 1. Summary

A route-level repair primitive exists and works. It is a downstream patch to
Debian's FRR.

The alternative -- reconciliation inside DANOS -- has not been built, and the
question this document exists to support is not "which is cheaper" but **what
each one actually requires**. For the FRR option that is measured. For the
DANOS-native option it is a set of semantics the current system does not have,
identified from what the code does rather than from what an implementation
might cost.

The most consequential finding is not about either option:

> The current data plane state model answers *"what happened when we tried to
> program this object?"* It does not answer *"what should this object be?"*
> Those are different questions, and no component in the path answers the
> second one about programmed state.

Everything below follows from that.

## 2. What the PoC proved

Measured on the built image, `i-danos_2608_20260915T2330`:

| | |
|---|---|
| Patch | 151 lines, one file, FRR 10.3 |
| Build | complete FRR build, 0 errors, 0 warnings |
| P1 — scope on a present route | 6/6 |
| P2 — repair of a genuinely missing route | 7/7 |

P2's shape matters more than its pass count. The route was lost **on the wire**,
by a filter between zebra and brokerd, so the drift came from a delivery
failure rather than from a component being told to pretend. The repair then put
it back with one message, over the live session, with the data plane's pid
unchanged.

That last clause is what the experiment was for. This project already had a
path that ends with routes present -- brokerd crashes, the FPM session drops
with it, zebra reconnects and walks its whole RIB -- and it was once recorded as
a repair primitive on exactly that evidence. **Route-level repair and
session-level recovery are now distinguishable, and the pid is what
distinguishes them.**

What the PoC did not prove: anything about maintaining the patch, and anything
about the other option.

## 3. The current state model

What exists, per object, in the data plane:

```
Object exists in a software table
          │
          ▼
    pd_obj_state
          ├── FULL          programmed in hardware
          ├── PARTIAL       partially programmed
          ├── NO_RESOURCE   hardware had no room
          ├── NO_SUPPORT    no hardware or software support
          ├── NOT_NEEDED    hardware does not need it
          └── ERROR         programming failed
```

Every value describes a **programming attempt on an object that exists**. The
enum has no value for an object that ought to exist and does not, because such
an object has nowhere to carry a state -- it is simply absent from the table.

Carried alongside it: a 4-bit backend field, `dataplane_owned` (tri-state, from
`rt_is_reserved()`), and per-route metadata the data plane already keeps --
prefix, scope, table, vrf, protocol, next-hop index and refcount. Software and
hardware outcomes are already separated, as `route_sw_stats[]` and
`route_hw_stats[]`, though only for the route and vrf classes.

### Why `dpa-drift.py` is external

This reframes a tool that already exists. It was not an architectural
preference to compare from outside:

> Drift can only be produced by comparison because divergence between desired
> and programmed is not representable anywhere inside the system. There is no
> field to read, so there is nothing to read it from.

This is also the answer to "why not just use `pd_obj_state` for
reconciliation": it reports the outcome of an attempt, not an intent.

## 4. Four constraints

Each was found by reading the code and confirmed at runtime where confirmation
was possible.

### D1 — There is no desired-state store

`pd_obj_state`'s domain is objects that exist. Nothing in the data plane,
brokerd, or the FPM path records that an object *should* exist.

Reusable if reconciliation is built: the per-object state and backend fields,
the uniform `dpa object show` view, the software/hardware split, the
`dataplane_owned` discriminator, and the per-route metadata already stored.

Missing: existence intent. Not unimplemented -- outside the model's domain.

### D2 — "Should be here and isn't" cannot be expressed

Three states a reconciler must tell apart:

| | Expressible today |
|---|---|
| A. desired absent | as absence, and **not distinguishable from never-existed** |
| B. desired present, programmed absent | **no** |
| C. desired present, programmed, operationally failed | partially, as hardware state |

Evidence for B: when the software LPM is full, the code increments
`route_sw_stats[PD_OBJ_STATE_NO_RESOURCE]` and returns. A counter moves; no
object is created. The data plane can say *N routes failed for lack of
resource* and cannot say *which*.

Evidence for A: deleting a route that is not present returns an error and
records nothing -- the comment at that branch reads "Can happen when trying to
delete an incomplete route", so it is an expected condition. There is no
tombstone.

C is partial because `ERROR`, `NO_RESOURCE` and `PARTIAL` describe the hardware
attempt while the object remains in software and forwards. A software-side
failure has no per-object representation at all.

### D3 — A route's state can belong to its next-hop group

The data plane does not order route programming behind next-hop group
programming. When a group is not fully programmed, the route is programmed
anyway, pointing at the blackhole group:

```c
if (nextl->pd_state != PD_OBJ_STATE_FULL &&
    nextl->pd_state != PD_OBJ_STATE_NOT_NEEDED)
        nextl = nh_common_get_blackhole(family);
```

and the route then **inherits the group's state**, its own return code
discarded:

```c
if (nhl_pd_state != PD_OBJ_STATE_FULL &&
    nhl_pd_state != PD_OBJ_STATE_NOT_NEEDED) {
        pd_state->state = nhl_pd_state;
        update_pd_state = false;
}
```

Withdrawal runs the other way and is refcount-driven: the group's FAL objects
are released when the last route referring to it goes.

```
       programming            withdrawal
   Route ─────────┐        Route ─────────┐
                  ▼                       ▼
          (no wait; blackhole      refcount-- ; at zero
           substituted if NHG       the NHG's FAL objects
           is not ready)            are deleted
```

So a route reading `NO_RESOURCE` may have nothing wrong with it. A reconciler
that repairs per object, without reading the dependency, would re-send a route
whose actual problem is its next-hop group.

### D4 — Two disjoint sources, and brokerd owns neither

```
   Protocol routes                     Connected routes
        │                                    │
        ▼                                    ▼
    Zebra RIB                             Kernel
        │                                    │
       FPM                            RTPROT_KERNEL only
        │                                    │
        └──────────────┬─────────────────────┘
                       ▼
                    brokerd
                       │
                       ▼
                   dataplane
```

brokerd's kernel netlink socket carries a BPF filter accepting only
`RTPROT_KERNEL`, and its startup dump applies the same test -- the comment
there reads "Handle kernel routes only - others come from FPM". Confirmed at
runtime: a static route installed by zebra appears in the kernel as
`proto static`, which that filter rejects.

Two boundaries follow, and both correct assumptions this project previously
held in writing:

```
brokerd     = aggregation and delivery point,  not a desired-state owner
kernel FIB  = the source for connected routes, not a backup copy of the RIB
```

brokerd's hash is a coalescing queue: `rib_route_delete()` removes each entry on
delivery. The second line corrected three documents, which had recorded that a
brokerd restart re-seeds the whole table from the kernel FIB. It does not. What
restored twenty protocol routes in that incident was zebra's reconnect walk.

## 5. Option A — downstream FRR route replay

Exists, measured, in this repository as
`frr-poc/0001-fpm-replay-one-route.patch`.

Mostly extraction: `fpm_rib_send()`'s reconnect walk already regenerates a
route's FPM message from `dest->selected_fib`, and its loop body becomes a
function both paths call. The new part is naming one destination. No new state
in any component; the authority is zebra's `selected_fib`, which it maintains
already and encodes from on every reconnect.

The constraints above mostly do not apply to it, and the reason is worth
stating plainly: **it does not reconcile.** It re-sends what zebra holds when
something outside decides a route should be re-sent. Existence intent is
supplied by the RIB lookup at the moment of the call; there is nothing to store
between calls.

D3 is the exception. Replaying a route whose next-hop group is the actual
problem will re-send the route and not fix it. The primitive returns named
errors, so it can report `ENODATA` when zebra has the prefix with nothing
installed -- but a route pointing at a blackhole group because the group failed
is, to zebra, installed.

## 6. Option B — reconciliation inside DANOS

Not built. What follows is the minimum set of semantics that D1–D4 say it would
have to add, derived from what the system does not currently express. It is not
a design, and there is no implementation to measure.

**1. Existence intent.** A representation of "this object should exist",
separable from "this object exists". D1: the current model has no domain for it.

**2. Desired/programmed divergence.** State B must be expressible for a named
object, not as an aggregate counter. D2.

**3. Withdrawal semantics.** Deletion must be distinguishable from programming
failure. Today both end as absence, and absence is also indistinguishable from
never-existed. D2.

**4. Dependency-aware evaluation.** A route's state cannot be read without its
next-hop group's, because it may *be* its next-hop group's. D3.

**5. Source separation.** Protocol routes and connected routes arrive from
different authorities and cannot share one desired-state domain without deciding
which authority wins where. D4.

Each is a semantic requirement, not a component. Whether they become one store,
several, or annotations on what exists is a design question this material does
not answer.

## 7. Evidence and unknowns

| | Option A | Option B |
|---|---|---|
| Evidence level | implementation + runtime measurement | source constraints only |
| Authoritative route state | zebra `selected_fib` | **owner undecided** |
| Desired-state store | none added | **must be added** (D1) |
| Programmed state | existing FPM and data plane | existing `pd_obj_state` reusable |
| "Missing object" state | resolved per call by RIB lookup | **must be expressible** (D2) |
| Withdrawal / tombstone | not needed | **must be added** (D2) |
| NH/NHG dependency | not handled; see D3 caveat | **reconciler must understand it** (D3) |
| Source separation | inherited from the existing path | **must be decided** (D4) |
| Route repair demonstrated | P2, 7/7 | none |
| Code and build cost | measured | **UNKNOWN** |
| Runtime cost | not measured for either | **UNKNOWN** |
| Version maintenance | FRR rebase, described below | DANOS's own surface |

## 8. Maintenance surface

For option A, observed rather than estimated:

1. The patch is 151 lines in one file.
2. **The DANOS build container cannot build FRR 10.3.** It carries this
   project's libyang 1.0.184 against FRR's requirement of 2.1.128. The PoC was
   built in a clean Debian 13 container.
3. So the patch comes with a second build environment to keep.
4. Each FRR version bump is a full FRR build: `zebra/zebra` alone fails on
   generated protobuf headers.
5. A rebase is not finished when the patch applies. The patch reaches into
   zebra's internal structures -- `rib_dest_t`, `selected_fib`,
   `RIB_DEST_UPDATE_FPM`, the `zrouter.master` / FPM-thread split -- any of
   which upstream can reorganise without the patch failing to apply. P1 and P2
   have to be re-run.
6. Upstream has no equivalent command, so there is no version of this that
   arrives for free in a later FRR.

For option B: UNKNOWN. It has no build, no rebase cycle and no test suite
because it has no implementation. Stating it as "lower" because it is in-house
would be an assumption, not an observation.

## 9. What each option requires

**A requires** a decision to carry a downstream FRR patch, the environment to
build it, and the discipline to re-run P1 and P2 on every rebase rather than
treating a clean `git apply` as success.

**B requires** the five semantics in section 6 to be specified before anything
is built, because four of them change what the existing state model means
rather than adding to it.

Neither excludes the other in time. A supplies a primitive; B would supply the
thing that decides when to call one. That they compose is an observation about
their shapes, not an argument for doing both.

## 10. Questions the decision turns on

1. Is a downstream FRR patch acceptable as a standing commitment, given that
   its correctness depends on internals upstream may reorganise silently?
2. If reconciliation is eventually built in DANOS, does A's primitive remain
   useful to it, or is it displaced?
3. Who owns desired state for protocol routes -- zebra, or a DANOS-side store
   that would then have two writers to reconcile against each other?
4. Does the D3 caveat matter for the failures actually seen? No measurement
   exists of how often a route's programming state is inherited from its
   next-hop group rather than its own.
5. Is there a third position -- neither a patch nor a reconciler -- that the
   evidence here does not rule out?

## 11. Non-conclusions

Not established by anything in this document, and not to be filled in with
estimates:

- **The size, effort or duration of option B.** No implementation exists.
- **The runtime cost of either option.** Not measured. P1 and P2 measured scope
  and effect, not throughput, latency or behaviour under load.
- **That option A is "cheap".** Its code surface is small and measured; its
  build and version surface is real and described. Those are different
  statements.
- **That option B is "complex".** Five semantic requirements were identified.
  Whether that makes an implementation large is not something section 6 can
  tell you.
- **How often repair is actually needed.** No measurement of drift frequency in
  normal operation exists. Both options answer a problem whose rate is unknown.
- **Whether route-level repair is sufficient.** Only IPv4 unicast routes were
  exercised. Nothing here covers IPv6, multicast, MPLS, next-hop groups as
  repair targets, or the other five object classes the DPA model enumerates.
- **A recommendation.** Deliberately absent.
