# EVPN IRB: asymmetric works today, symmetric is a dataplane project

Status: **asymmetric IRB verified working on the built image with no dataplane
change and no new configuration model, and ARP suppression built on top of
it.** Symmetric IRB was the piece originally asked for; measuring first showed
it needs three dataplane features that do not exist here at all.

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

Symmetric is what the industry settled on, and it is the better design. That
is a reason to want it, not evidence that it is reachable.

## What the platform has

`probe-irb-viability.sh` asked the cheap question first.

**Symmetric IRB has nothing to build on.** `l3vni`, `rmac` and `svi` match
nothing in `vyatta-dataplane/src`, and the FAL headers carry no hooks for
them. It needs a VNI that maps to a VRF for routed traffic, a router-MAC table
per remote VTEP, and a decapsulate-then-route-then-re-encapsulate path, plus
the zebra plumbing to fill all of it. That is a feature comparable in size to
everything else done on EVPN here put together.

One thing invites a misreading: `vxlan.c` already has a `t_vrfid`, and it is
not the tenant VRF. It is the transport VRF the *outer* packet is looked up
in. A symmetric IRB L3VNI is about the inner packet.

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
- **That symmetric IRB is not worth building.** It is the better design and
  the reason is exactly the weakness above. What changed is the estimate: it
  is a dataplane project, to be scheduled as one, and asymmetric IRB is worth
  having in the meantime because it costs nothing.
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
