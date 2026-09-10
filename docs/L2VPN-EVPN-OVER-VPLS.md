# L2VPN: EVPN-VXLAN rather than VPLS

Status: **measured, and the recommendation has changed.** The roadmap carried
VPLS/VPWS as the remaining L2VPN item. Four of the five pieces EVPN-VXLAN needs
are already here and working; VPLS has none of them. The single missing piece
is one well-defined mechanism, not a forwarding plane.

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
| Local MAC: dataplane → kernel → BGP | **no such path** |

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

## The one gap

Locally learned MACs never leave the dataplane:

```c
/* bridge_rtupdate(), bridge.c */
fal_br_new_neigh(ifp->if_index, vlan, dst, 1, &attr);
```

Learning updates the dataplane's own `bridge_rtnode` table and reports to FAL —
the hardware abstraction — and to nothing else. zebra reads the *kernel* bridge
FDB to decide which local MACs to advertise as EVPN type-2 routes, so it sees
none. `show evpn vni` reports `# MACs 0` while the dataplane's own table holds
several dynamic entries on the same interface.

So EVPN needs one mechanism added: a notification from the dataplane's learning
path to the kernel FDB, for bridge ports that belong to a VXLAN-backed bridge.
FAL is already the hook for "tell someone else about this MAC"; a netlink
notification alongside it is the same shape.

## Why this is cheaper than VPLS

| | VPLS/VPWS | EVPN-VXLAN |
|---|---|---|
| Forwarding plane | from nothing | measured working |
| Remote MAC programming | from nothing | measured working |
| Control plane | ldpd pseudowire signalling, from nothing | bgpd, shipped, session up |
| Control plane to interface model | from nothing | zebra finds the VNI on its own |
| Remaining work | pseudowire encapsulation, signalling, split horizon, per-PW learning | local MAC reporting |

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

`toolkit/vm/verify-vxlan-evpn-viability.sh` and
`toolkit/vm/verify-evpn-last-hop.sh`, on `TOPO=ipsec`.

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

That EVPN works. Four pieces work and the fifth is missing; nothing has carried
a MAC end to end from one router's learning to the other's forwarding table.
The next step is the local-MAC notification, and then that end-to-end test —
in that order, because the test cannot pass before the mechanism exists.
