# L2VPN: EVPN-VXLAN rather than VPLS

Status: **done, end to end.** The roadmap carried VPLS/VPWS as the remaining
L2VPN item. Four of the five pieces EVPN-VXLAN needs were already here; the
fifth has since been written, and a MAC learned on one router now reaches the
other's forwarding table. VPLS has none of the five and is not worth starting.

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
| Remaining work | pseudowire encapsulation, signalling, split horizon, per-PW learning | **none: done** |

EVPN is also what VPLS was replaced by. Choosing it is not only cheaper here,
it is the direction the rest of the industry already went.

## Two defects found on the way, neither blocking

**`vxlan macs show` prints the wrong fields.** The MAC appears in the `IPAddr`
field and every entry reports `type: local`, including one injected with a
remote VTEP. The netlink parsing is correct — `vxlan_neigh_change()` reads
`NDA_DST` as an IPv4 address and passes it to `vxlan_newneigh()` — so this
looks like the dump function rather than the data. Not confirmed: the test
established that the entry *arrives*, not that it forwards.

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

Two smaller things remain, neither blocking:

- `vxlan macs show` prints the wrong fields, as above.
- Nothing has measured traffic actually forwarding to a remote MAC learned this
  way. The entry is present in the far dataplane; that it is *used* has not been
  established, and the difference is exactly the kind this project keeps finding.
