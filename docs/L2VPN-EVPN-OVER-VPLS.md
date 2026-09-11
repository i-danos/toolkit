# L2VPN: EVPN-VXLAN rather than VPLS

Status: **the control plane carries a MAC end to end; forwarding by it needed a
dataplane fix, and that fix is written but not yet measured on a built image.**
The roadmap carried VPLS/VPWS as the remaining L2VPN item. Four of the five
pieces EVPN-VXLAN needs were already here; the fifth has since been written.
VPLS has none of the five and is not worth starting.

An earlier revision of this document said "done, end to end" and claimed
forwarding had been proven. It had not been -- see
[The test that proved nothing](#the-test-that-proved-nothing) below. The
correction is kept rather than edited away because the way the wrong answer
arrived is the reusable part.

`ARCHITECTURE-ASSESSMENT.md` put VPLS under "New dataplane work" on the
strength of a keyword sweep — `pseudowire`, `vpls`, `l2vpn` all zero. That was
correct about VPLS and said nothing about the alternative, because nobody swept
for `vxlan`. It has 16 files and 2167 lines in `src/if/vxlan.c`.

## What was measured

Two routers on the `ipsec` topology, R1 and R2, sharing 10.60.60.0/24.

| Piece | Result |
|---|---|
| VXLAN forwards, bridge mode | **ping 4 of 4** over VNI 100 |
| zebra learns the VNI from a DANOS VXLAN interface | **`100  L2  tun0`**, unprompted |
| bgpd accepts `address-family l2vpn evpn` | **session Established**, 35s uptime |
| Remote MAC: kernel FDB → dataplane | **arrives**, VNI intact |
| Local MAC: dataplane → kernel → BGP | **no such path** — written since, see below |

The remote-MAC test deliberately bypassed BGP. FRR programs a remote MAC by
writing a bridge FDB entry on the VXLAN device with `NDA_DST` set to the remote
VTEP, so injecting that message by hand tests the same code with none of BGP's
policy machinery in the way:

```
$ sudo bridge fdb add 02:00:00:00:00:01 dev tun0 dst 10.60.60.2
$ sudo vplsh -l -c "vxlan macs show"
    { "mac": "2:0:0:0:0:1", "VNI": 100, ... }
```

`bridge.c` routes those messages to VXLAN before the ordinary bridge handler:

```c
if (ifp && ifp->if_type == IFT_VXLAN && vxlan_get_vni(ifp))
        skip = vxlan_neigh_change(nlh, ndm, tb);
```

## The gap, and how it was closed

Locally learned MACs never left the dataplane:

```c
/* bridge_rtupdate(), bridge.c */
fal_br_new_neigh(ifp->if_index, vlan, dst, 1, &attr);
```

Learning updated the dataplane's own `bridge_rtnode` table and reported to FAL
-- the hardware abstraction -- and to nothing else. zebra reads the *kernel*
bridge FDB to decide which local MACs to advertise as EVPN type-2 routes, so it
saw none. `show evpn vni` reported `# MACs 0` while the dataplane's own table
held several dynamic entries on the same interface.

The bridge now reports them. Three decisions in that are worth keeping:

**From the ageing timer, not from the learning path.** `bridge_rtupdate()` runs
per packet per core and has no business making a syscall. The timer already
walks the whole table every two seconds on the master lcore, and two seconds is
immaterial to EVPN, which takes longer than that to converge.

**Only for a bridge with a VXLAN member.** That is what puts zebra in the
picture. Every other bridge's kernel FDB is read by nothing, and filling it
would be churn for no reader.

**Not MACs learned on the VXLAN interface.** Those arrived from the far side
and belong to somebody else; reporting one as local would have zebra advertise
it back as a route owned by this VTEP. The first version did exactly that --
the kernel FDB filled with four entries and every one of them was `dev tun0`.
The mechanism worked and was pointed the wrong way, which is a failure that no
test of "did anything reach the kernel" can see.

## Measured end to end

One MAC, every hop, on `TOPO=ipsec` with R2 bridging a local port toward R3:

| Hop | Reading |
|---|---|
| R2 dataplane learns it locally | `"mac":"52:54:0:3:8:1","port":"dp0s8"` |
| R2 kernel FDB | `52:54:00:03:08:01 dev dp0s8 master br0` |
| R2 zebra | `# MACs 1`, `52:54:00:03:08:01 local dp0s8` |
| BGP type-2 | `[2]:[0]:[48]:[52:54:00:03:08:01]` and `...:[32]:[10.61.61.3]`, RT `65000:100` |
| R1 zebra | `52:54:00:03:08:01 remote 10.60.60.2` |
| R1 kernel FDB | `52:54:00:03:08:01 dst 10.60.60.2 self extern_learn` |
| R1 dataplane | present |

`# MACs 1` rather than more is the point: only the locally learned MAC is
advertised, which is the third decision above being visibly right. The two
type-2 routes -- MAC-only and MAC+IP -- mean the information ARP suppression
needs is there as well.

The five Robot suites pass 74 of 74 on the same image, which matters here
because the change adds a syscall to a bridge timer.

## Why this is cheaper than VPLS

| | VPLS/VPWS | EVPN-VXLAN |
|---|---|---|
| Forwarding plane | from nothing | measured working |
| Remote MAC programming | from nothing | measured working |
| Control plane | ldpd pseudowire signalling, from nothing | bgpd, shipped, session up |
| Control plane to interface model | from nothing | zebra finds the VNI on its own |
| Remaining work | pseudowire encapsulation, signalling, split horizon, per-PW learning | YANG/CLI, and confirming the forwarding fix on a built image |

EVPN is also what VPLS was replaced by. Choosing it is not only cheaper here,
it is the direction the rest of the industry already went.

## The test that proved nothing

The hop table above stops at "R1 dataplane: present". The obvious next question
is whether R1 *forwards* by it, and the first attempt at answering it went
wrong in a way worth recording.

Reachability alone cannot separate "forwards because of the EVPN entry" from
"forwards because flooding reached the same place" — with one remote VTEP both
go to the same address. So the flood path was made a dead end: R1's tunnel
`remote-ip` was set to 10.60.60.99, which nothing answers, while the EVPN entry
named the real VTEP 10.60.60.2. Measured in both states, the ping failed before
EVPN and succeeded after, and that was read as proof.

It is not proof, because R1 and R2 are bridged. Blocking the flood path *out of*
R1 does nothing about learning *into* R1: every frame R2 floods toward R1
teaches R1 the source MAC together with the source VTEP. Dumping the table
instead of inferring from reachability showed R3's MAC already sitting in R1
before EVPN was configured at all:

```
"mac": "52:54:0:3:8:1", "IPAddr": "10.60.60.2", "type": "dynamic"
```

`dynamic` is the data path's own learning. The entry that carried the traffic
was never the EVPN one. (`IPAddr` is the old field name; the probe ran on the
image that was installed, before any of the fixes below.)

The same dump showed something worse. Once EVPN programmed that MAC, the entry
lost its VTEP — the field printed the MAC string instead of an address, which
is what this dump does when neither address flag is set. `vxlan_output()` tests
those same flags:

```c
if (vxlrt->vxlrt_flags & IFBAF_ADDR_V4) { ... }
else if (vxlrt->vxlrt_flags & IFBAF_ADDR_V6) { ... }
else
        goto drop;
```

`vxlan_newneigh()` set neither, so **no MAC that EVPN learns was forwardable**,
and a netlink update about a MAC the data path already knew *cleared* the flag
off a working entry and turned it into a black hole until the data path learned
it again. Its update branch also never refreshed `vxlrt_dst`, which is how a
MAC move is signalled, so a moved host would have gone on being encapsulated to
the VTEP it had left.

Two things made this survive as long as it did:

- **The symptom looked cosmetic.** A MAC in an address field reads as a
  formatting bug. It was the visible end of a forwarding defect, and it was
  filed as a display nuisance for two rounds.
- **The test was built from the product's own reachability.** Every signal it
  used was one the defect could satisfy by accident. Asking the table what it
  held took one command and answered immediately.

`toolkit/vm/probe-vxlan-mac-origin.sh` is that probe; `verify-evpn-forwarding.sh`
has been rewritten around the distinction the table makes — `type: permanent`
is netlink's, `type: dynamic` is the data path's — rather than around where
traffic can reach.

## Two defects found on the way

**`vxlan macs show` printed the wrong fields — fixed, and it was not cosmetic.**
One buffer was shared between the MAC and the VTEP, so an entry with no address
flag printed the leftover MAC in the VTEP field; that buffer was also
`INET_ADDRSTRLEN`, two bytes short of what `ether_ntoa_r()` can write and thirty
short of an IPv6 address. The dump now uses separate, correctly sized buffers,
names the field `remote_ip` rather than `IPAddr` (it is the VTEP, never the host
address an EVPN type-2 route also carries), says outright whether the entry can
forward, and prints `permanent` where it used to print `local` — which was read
as a claim about where the MAC lives, the opposite of the truth for a remote
VTEP. MACs print zero-padded via `ether_ntoa_canon()`, because `ether_ntoa_r()`
drops leading zeros and nothing else in the stack does: comparing this output
against the kernel or FRR meant comparing `52:54:0:3:8:1` against
`52:54:00:03:08:01`, which silently matches nothing. That mismatch is what let
the first forwarding test report "not in the dataplane" and be dismissed as a
grep problem.

**eBGP needs a policy or the session carries nothing.** With AS 65001 and
65002, `show bgp l2vpn evpn summary` reports `(Policy)` in place of a prefix
count and no routes are exchanged. FRR has defaulted to
`bgp ebgp-requires-policy` since 7.4. Use iBGP for a lab, or disable it
explicitly.

## Reproducing

`toolkit/vm/verify-vxlan-evpn-viability.sh`, `verify-evpn-last-hop.sh` and
`verify-evpn-e2e.sh`, on `TOPO=ipsec`. The last is the one that walks all five
hops; it needs three routers, because R2 has to bridge a local port with
something behind it. An earlier version bridged only the tunnel at both ends,
which left nothing local to advertise -- "0 MACs" was then the correct answer
to a question worth nothing.

Three things about the harness are worth knowing, because each produced a
confident wrong answer first:

- **The interface must be named `tunN`.** `vxl0` fails validation on every
  `set`, the tunnel is never created, and a script that only checks the ping
  reports "VXLAN does not forward" — a verdict about a typo. Both scripts now
  check the tunnel exists before believing anything about forwarding.
- **VXLAN carries Ethernet frames, so the tunnel goes in a bridge.** An address
  on `tun0` brings the tunnel up in both the kernel and the dataplane and
  transmits nothing. The address belongs on the bridge.
- **`bgpd=yes` is already in the shipped `daemons`.** A cleanup that deletes
  the line removes something that was there by default and leaves the router
  without bgpd for every later run.

## What this does not say

That EVPN-VXLAN is finished as a product feature. What has been shown is that
the mechanism carries a MAC end to end, using the control plane FRR ships and
the interfaces DANOS already models. There is no YANG for any of it: every EVPN
knob in these runs was typed into `vtysh` by hand, and the tunnel was
configured through the existing tunnel model rather than anything EVPN-aware.
A CLI is the next piece of work, and it is ordinary work -- the part that was
uncertain no longer is.

What is outstanding:

- **The forwarding fix is written and compiles; it has not run.** Until
  `verify-evpn-forwarding.sh` passes on an image built from it, the honest
  statement is that EVPN-learned MACs were *known* not to forward and are
  *believed* to now.
- **IPv6 VTEPs do not arrive over netlink at all.** `vxlan_neigh_change()`
  rejects any `NDA_DST` that is not four bytes, so `IFBAF_ADDR_V6` can only
  ever be set by data-path learning. EVPN over an IPv6 underlay is therefore
  not supported, and nothing currently says so to the operator.
- **Nothing tests a MAC move.** The update path now refreshes the VTEP, which
  is the behaviour a move depends on, and no test exercises it.
