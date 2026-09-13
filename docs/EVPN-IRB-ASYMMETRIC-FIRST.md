# EVPN IRB: both datapaths work today; the gap is the control plane

Status: **both IRB datapaths verified working on the built image with no
dataplane change, ARP suppression built on top of the asymmetric one, and
symmetric IRB now configurable from the CLI.** Symmetric IRB was the piece originally asked for.
Measuring first said it needed three dataplane features that do not exist --
and measuring again, properly, showed it needs none of them. The remaining
work in both cases is the control plane.

## The question

Inter-subnet routing in an EVPN fabric comes in two shapes, and they are not
variations on one design:

| | Asymmetric | Symmetric |
|---|---|---|
| Where routing happens | ingress leaf only | both leaves |
| VNIs each leaf must host | all of them | only its own |
| Transit encapsulation | the destination L2VNI | a dedicated L3VNI |
| Needs a router-MAC table | no | yes |
| Scales to a large fabric | poorly | yes |
| Works on this dataplane | **measured, 9 of 9** | **measured, 4 of 4** |
| Configurable from the CLI | needs no new model | **measured, 16 of 16** |

Symmetric is what the industry settled on, and it is the better design. That
is a reason to want it, not evidence that it is reachable.

## What the platform has

`probe-irb-viability.sh` asked the cheap question first.

**Symmetric IRB was declared to have nothing to build on, and that was
wrong.** The claim rested on `l3vni`, `rmac` and `svi` matching nothing in
`vyatta-dataplane/src`. That is evidence about vocabulary, not about
mechanism, and measuring settled it the other way: `probe-symmetric-irb.sh`
forwards 4 of 4, with the two routed hops a traceroute should show and with
the ingress leaf holding none of the destination's VNI.

What FRR calls an L3VNI is a bridge whose only member is a VXLAN tunnel and
whose SVI is in the tenant VRF. What it calls a router MAC is that SVI's MAC,
resolved by ordinary ARP like any other next hop. The decapsulate-then-route
path is a frame arriving addressed to the bridge's own MAC, delivered locally,
and routed by an SVI that happens to be in a VRF. Every piece was already
here under a different name.

The same mistaken reasoning appears twice in this document -- it was made
about asymmetric IRB first, and repeated about symmetric IRB in the paragraph
that used to stand here. Grepping for a feature's name answers whether the
codebase uses that word.

One thing still invites a misreading: `vxlan.c` has a `t_vrfid`, and it is not
the tenant VRF. It is the transport VRF the *outer* packet is looked up in.

**Asymmetric IRB had every piece already.** A bridge with an address is a
first-class routing-instance member -- FRR, the kernel and the dataplane all
agree:

```
C>* 10.10.10.0/24 is directly connected, br10        FRR, vrfRED
10.10.10.0/24 dev br10 proto kernel                  kernel, vrfRED
br10  vrf=19  addrs=['10.10.10.1/24']                dataplane
```

The first version of that probe created the bridges empty and reported an
empty routing instance, which reads exactly like a platform where bridges are
not VRF-aware. A bridge with no member port has no carrier, so the kernel
holds it down and installs no connected route. Anything measured on a bridge
needs a port in it first, or the measurement is about carrier.

## What was verified

`verify-asymmetric-irb.sh`, 9 of 9 on `i-danos_2608_20260911T2143`:

| Check | Result |
|---|---|
| Both bridge domains in the tenant VRF | `br10` and `br20` connected in `vrfRED` |
| Neither in the default table | tenant is isolated |
| A host in VNI 10 reaches a host in VNI 20 on another leaf | **4 of 4** |
| The path actually crosses the IRB | traceroute: `10.10.10.1` then `10.20.20.3` |
| zebra binds each VNI to the tenant VRF | `10 L2 tun10 … vrfRED`, `20 L2 tun20 … vrfRED` |
| EVPN holds the far host's IP as well as its MAC | `10.20.20.3 … 52:54:00:03:08:01` |
| Still forwards once EVPN is configured | **4 of 4** |

The traceroute is not decoration. With R2 doubling as the host, a shortcut to
its own `br20` would have produced a passing ping that said nothing about IRB
-- the same trap as the first EVPN forwarding test, where flooding and the
EVPN entry led to the same place. A static route on R2 pointing at R1's SVI
forces the traffic across, and the traceroute confirms it went.

The earlier probe sourced traffic from R1's own SVI, so the packet was already
on the router that routes it. This test puts the host a leaf away, so the
first hop is a packet arriving over a tunnel, bridged into the ingress VNI,
and only then routed -- the hop where a bridge that is VRF-aware for
locally-originated traffic could still fail.

## zebra derives the VNI-to-VRF binding by itself

```
VNI        Type VxLAN IF   # MACs   # ARPs   # Remote VTEPs  Tenant VRF
10         L2   tun10      0        1        0               vrfRED
20         L2   tun20      1        1        1               vrfRED
```

Nothing configured that column. zebra reads the bridge's routing-instance
membership and attaches the VNI to it. This is the same pattern as zebra
finding the VNI on a DANOS VXLAN interface unprompted: the control plane
already understands more of this model than the roadmap assumed.

## What is left

**Nothing, to make it work.** The configuration is entirely existing model:

```
set interfaces bridge br10 address 10.10.10.1/24
set interfaces tunnel tun10 encapsulation vxlan
set interfaces tunnel tun10 vxlan-id 10
set interfaces tunnel tun10 bridge-group bridge br10
set routing routing-instance RED interface br10
set protocols bgp 65000 address-family l2vpn-evpn advertise-all-vni
set protocols bgp 65000 neighbor 10.60.60.2 address-family l2vpn-evpn
```

with the same again for the second bridge domain. The EVPN half of that is
new this week; the rest predates it.

## ARP suppression, which was the piece worth doing next

Done, and it turned out to be a knob and a reply path. One line:

```
set interfaces bridge br20 arp-suppression
```

`probe-arp-suppression.sh` sized it before anything was written, by asking
which half was missing. The information was already there: flush the
neighbour on a leaf and zebra puts it straight back from the EVPN route as
`extern_learn`, and the dataplane holds it against the bridge in the same
table the routing path reads. Only the behaviour had to be built --
`bridge.c` touched ARP solely to bypass the firewall. So no new table, no
netlink plumbing.

`verify-arp-suppression.sh`, 9 of 9 on `i-danos_2608_20260912T0211` -- a
later image than the asymmetric IRB run above, which is why the two cite
different ones:

| Check | Result |
|---|---|
| With it off, the request is encapsulated into the fabric | VXLAN `OutPkts` **+2** |
| With it on, the request is answered locally | `OutPkts` **+1** -- the ARP is the one that went |
| The bridge says it answered | `suppressed` 0 → 1, `flooded` unchanged |
| The answer carries the right MAC | R3 reaches the far SVI, 3 of 3 |
| An address the table never held still floods | `flooded` 0 → 3 |

The last row is the one that keeps this an optimisation rather than an
outage: a host EVPN has not advertised yet must still be reachable, at the
cost of one broadcast.

The five Robot suites pass 74 of 74 on the same image, which matters here
because the change puts a branch in the bridge's input path. It is behind
`likely(!sc->scbr_arp_suppress)` and returns before touching the frame when
the feature is off, but it is on the path every frame that would be flooded
takes.

### Two things the implementation had to get right

**It is for the hosts, not for the router.** A leaf with an SVI never ARPs for
a remote host -- zebra has already installed the neighbour, and deleting it
locally only makes zebra put it back. What floods is a host in the bridge
domain, which has no BGP session. The first version of the test drove the ARP
from the router's own stack and measured nothing at all, both counters at
zero, because no ARP was ever sent.

**Every leaf needs an SVI in every subnet it serves.** Only a leaf with an
address in the host's subnet learns the host's IP-to-MAC binding; a pure L2
leaf sees the MAC alone and advertises a MAC-only type-2 route, leaving
nothing to answer from. That is why the `flooded` counter is not decoration:
a count that keeps rising is the visible form of that configuration mistake,
and it is otherwise invisible -- ARP still resolves, just noisily.

### What the flooded counter actually counts

An operator is being asked to read that counter as a diagnosis, so it had
better mean one thing. The table above asserts it loosely -- `flooded 0 → 3`,
from one ping -- and that is not enough to tell a counter that counts once per
request from one that counts three times, because one ping is not one request:
the kernel's neighbour state machine sends up to three solicitations, backs
off, and caches the failure.

`verify-arp-suppression-flooded.sh` drives exact numbers of exact frames with
`send-arp.py` and asserts exact deltas. 17 of 17 on
`i-danos_2608_20260913T1546`:

| Frames sent | `suppressed` | `flooded` | `OutPkts` |
|---|---|---|---|
| 4 unanswerable, feature off | +0 | +0 | +4 |
| 12 idle seconds | +0 | +0 | -- |
| 5 unanswerable | +0 | **+5** | +5 |
| 5 answerable | **+5** | +0 | +0 |
| 3 answerable + 2 not | **+3** | **+2** | -- |
| 4 ARP replies | +0 | +0 | +4 |
| 4 non-ARP broadcasts | +0 | +0 | +4 |
| 4 for the same address, now learned | **+4** | +0 | +0 |

The first row is the design showing through: with the feature off the fast path
returns before the counters, so a feature nobody enabled costs nothing -- and
`OutPkts +4` is there so that "the counters did not move" cannot be confused
with "nothing was sent". The second row is what makes every exact delta below
it a statement about the frames rather than about background traffic.

The last row is the counter's whole point. Nothing changed but whether the
neighbour table could answer: the same address that flooded four frames
earlier stops flooding entirely. A rising `flooded` is therefore a condition
with a cause, not a statistic -- which is what lets it diagnose the missing-SVI
mistake above.

### One thing it counted that it should not

A request for the bridge's **own** SVI address used to raise `flooded`:

```
sent 3 request (10.20.20.2, which is R2's own br20 address)
    suppressed +0    flooded +3    OutPkts +3
```

It is answered -- the local copy is delivered to R2's L3 path before the
suppression check, which is deliberate and is why that ordering exists. But
the suppression check then looked `10.20.20.2` up in the neighbour table, which
does not hold an interface's own address (that is a route, not a neighbour),
read a miss, counted it, and let it flood.

So the one address a leaf is most certain about was the one address it did not
suppress, and the counter reported it as the same kind of event as a host the
fabric never advertised. On a quiet bridge that is a `flooded` climbing for no
reason an operator can find, sending them to look for an EVPN advertisement
problem that is not there.

`bridge_arp_suppress()` now returns before the lookup for an address the
bridge holds. The frame still floods -- a bridge floods broadcasts, duplicate
address detection on the segment depends on seeing them, and suppressing here
would also put a second reply on the wire behind the one the L3 path already
sent.

**Which "local" is the right one.** The obvious helper is `is_local_ipv4()`
(`route.h:92`), and it is the wrong one: it is VRF-scoped, so with `br10` and
`br20` both in `RED` it would call `10.10.10.2` local for a request arriving on
`br20`. Nothing would answer that request -- this dataplane replies to ARP only
for addresses on the *receiving* interface, which `arp_ignore()` in
`l3_arp.c:172` enforces, Vyatta behaviour equivalent to Linux `arp_ignore=1` --
so the guard would have stopped counting a miss that really is one. The new
`ifa_is_local()` in `in.c` asks the same interface-scoped question
`arp_ignore()` asks, and sits beside `ifa_broadcast()`, which was already
there asking a neighbouring one.

### Four measurements that measured nothing

Worth recording, because the shape was identical every time: a reading that
exists, parses, and does not carry the information.

| Attempt | Read | Why it said nothing |
|---|---|---|
| 1 | `[:12]` slice of the sorted key list | cut off at `rx_`, suggesting `tx_packets` did not exist |
| 2 | `tx_packets`, confirmed on `dp0s8` | confirmed on a physical port, used on a tunnel |
| 3 | `tun20` `tx_packets` | the field exists and is never incremented |
| 4 | `vxlan stats` `OutPkts` | incremented on the send path -- correct |

Attempt 3 is the instructive one. A VXLAN interface transmits by building the
outer packet and handing it to the underlay port, so the tunnel's own counter
stays at zero while the tunnel carries traffic. It read `0 -> 0` across an ARP
that had demonstrably crossed, since the far host resolved the address. A
legitimate zero and a meaningless zero are indistinguishable from the reading
alone.

The product's four substantive checks passed on the first run that generated
an ARP at all. All four of these were the corroborating measurement.

## What this does not say

- **That asymmetric IRB scales.** It was measured with one tenant, two bridge
  domains and two leaves. Its known weakness is that every leaf must host
  every VNI, and nothing here measured what that costs.
- **That symmetric IRB needed anything built.** It did not. The datapath
  works, FRR drives it, and it is now configurable:

  ```
  set routing routing-instance RED vni 5000
  set routing routing-instance RED protocols bgp 65000 \
      address-family ipv4-unicast redistribute connected
  set routing routing-instance RED protocols bgp 65000 \
      address-family l2vpn-evpn advertise-ipv4-unicast
  ```

  `verify-symmetric-irb-cli.sh`, 16 of 16 on `i-danos_2608_20260913T1546`,
  with 74 of 74 beside it: the model emits the vrf block and the VRF's BGP
  instance, zebra takes the VNI as L3 against the tenant, the type-5 arrives
  carrying the far leaf's router MAC, zebra installs it against the remote
  VTEP with that MAC as a neighbour, and traffic takes the two routed hops --
  with the ingress leaf holding none of the destination's bridge domain.
- **That the test topology is realistic.** R2 holds a host address in one
  bridge domain while bridging the other, which a real leaf would not do. It
  is the only way to reach the ingress hop with three routers. Every hop R1
  performs is the real one, and R1 is what is under test.
- **Anything about IPv6.** Not measured.

## Reproducing

`toolkit/vm/probe-irb-viability.sh` (read-only, one router) and
`verify-asymmetric-irb.sh` (three routers, `TOPO=ipsec`).
`probe-asymmetric-irb.sh` is the earlier, weaker version kept because its
reading of `show evpn vni` is what turned up the VRF binding.

For suppression, `probe-arp-suppression.sh` (what is already there) and
`verify-arp-suppression.sh` (whether it stops the flood), both on
`TOPO=ipsec`. The verification needs all three routers and needs R2 to hold
an address in the host's subnet, for the reason above.

## Two integration seams worth knowing

Neither is a defect and both cost a run.

**A YANG module reaches nothing unless its component lists it.** A component
declares the modules it is responsible for in `Modules=` in its `.component`
file and receives nothing outside them.
`vyatta-protocols-frr-evpn-l3vni-v1` was not listed, so `vni` committed, was
in the configuration tree, appeared in `show configuration`, and never reached
FRR. The signature was `vrf vrfRED` immediately followed by `exit-vrf` -- and
that empty block was not even the L3VNI's, it belongs to `protocols/next-hop`,
which opens the same one. Read as "the mapping is wrong" it leads nowhere: the
mapping was correct and verified on the box.

**`advertise ipv4 unicast` advertises a BGP table, not a routing table.** A
connected subnet is not in the VRF's BGP IPv4 unicast RIB until something puts
it there. Without `redistribute connected` the command is accepted, appears in
the running config, and originates nothing, with no error -- which reads as
bgpd being unable to do this rather than as bgpd having nothing to advertise.
Both the YANG description and the test's failure hint now say so.
