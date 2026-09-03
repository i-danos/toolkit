# Multicast: what was already there, and what was missing

DANOS 2608 shipped with a working multicast dataplane that nothing could
configure. This records how that was established, and what the CLI written on
top of it does and does not cover.

## The gap was one layer, not four

| Layer | State before this work | Evidence |
|---|---|---|
| Dataplane forwarding | present, compiled in | `src/netinet/ip_mroute.c` 1612 lines, `src/netinet6/ip6_mroute.c` 1612 lines, `mcast_ip_deliver()` at `src/ip_forward.c:215`, all listed in `src/meson.build` |
| Netlink MFC ingest | present | `src/ip_netlink.c` parses `mfcc_mcastgrp` and `mf6cc` |
| FAL offload interface | present, unused | `src/ip_mcast_fal_interface.c` 316 lines; hardware support was dropped this round |
| `pimd` / `pim6d` | shipped, not enabled | in `frr 10.3-3+deb13u1`; `etc/frr/daemons.danos` listed only bgpd, isisd, ospfd, ospf6d, ldpd |
| CLI | **absent** | `vyatta-protocols-frr` exposed only bgp, isis, ldp, mpls, ospf, ospfv3, rip |

The forwarding code had not been modified since 2021 — `ip_mroute.c` last touched
2021-08-03, `ip_mcast.c` 2020-11-27 — and no `whole_dp` test covers any of it. It
compiles against DPDK 24.11 because it is in the build, but compiling is not
forwarding, and DPDK 20.11 to 24.11 changed enough in the mbuf and ethdev APIs
that this had to be proved rather than assumed.

## Proving the dataplane, before writing any CLI

Three routers in a chain, R1 source, R2 both RP and transit, R3 receiver.
Interfaces and OSPF through the DANOS CLI, because PIM's RPF check needs a
unicast route back to the source; PIM itself straight into `vtysh`, because
that was the whole point.

The instrument is the dataplane's own command surface, reachable through
`/opt/vyatta/bin/vplsh` and defined in `src/rt_commands.c`:

```
multicast mif      multicast interface table
multicast route    the forwarding entries, and which path serves them
multicast fcstat   per-entry counters
```

This distinguishes "the kernel has an MFC entry but the dataplane never got it"
from "the dataplane is forwarding" — a distinction no amount of `show ip mroute`
can make.

**First reading, before any traffic.** The dataplane's interface table already
mirrored the kernel's exactly — `pimreg`, `dp0s9`, `dp0s10`, `lo1` against
`/proc/net/ip_mr_vif`. Netlink propagation of multicast interfaces works on
kernel 6.12 and DPDK 24.11. That was the largest single unknown and it was
settled before a packet was sent.

**After traffic.** 5000 UDP datagrams from R1 to 239.1.1.1:

```
R2  dp0s9   in  2998 -> 7998      dp0s10  out  0 -> 5000
R3  dp0s10  in  4997             dp0s9   out    4997
```

and R2's forwarding cache:

```
origin 65.1.1.2  group 239.1.1.1
packets 7998   bytes 1823544
wrong_if 0     punted 1     punts_dropped 0
forwarding: "fast/dataplane"
```

`punted 1` is the reading that matters. Exactly one packet went to the
controller to create the entry; the remaining 7997 were replicated in the DPDK
fast path. Nothing was dropped and nothing arrived on the wrong interface.

### The wrong turn on the way

The first run built the tree, brought up PIM neighbours, and forwarded nothing.
R2's `(65.1.1.2, 239.1.1.1)` carried flags `SFTP` — the `P` is Pruned — with an
empty outgoing list.

That was the test, not the product: the receiver's IGMP join had been put on
`dp0s10`, the interface facing the RP. PIM will not build a tree whose outgoing
interface is also its incoming interface. Moving the join to `dp0s9` cleared the
`P` immediately.

Worth recording because of how it presents. Neighbours up, RP elected, tree
built, counters at zero — it reads exactly like a broken forwarding path, which
is the thing the test existed to look for.

## What the CLI covers

`vyatta-protocols-frr` 1.16.0. 664 lines, no C, no translation code: the
config-to-FRR layer in this package is a declarative path map, so a protocol is
a JSON file plus YANG.

```
protocols pim
  rp <address> group <prefix>          rp <address> prefix-list <name>
  keep-alive-timer                     rp-keep-alive-timer
  register-suppress-time               join-prune-interval
  packets                              ssm prefix-list <name>
  spt-switchover infinity-and-beyond [prefix-list <name>]

interfaces <type> <name> ip pim
  hello-interval / hello-holdtime      dr-priority      use-source

interfaces <type> <name> ip igmp
  query-interval                       query-max-response-time
  last-member-query-count              last-member-query-interval
  join-group <group> [source <src>]    static-group <group> [source <src>]
```

Operational commands sit under `show protocols pim` and `show protocols igmp`.

Every generated command was extracted from the shipping `pimd` binary. The
`frr` repository in `danos-sources` is the retired 7.6 fork and is **not** what
the image installs — reading daemon lists or command syntax out of it gives
answers about software that is not there. This bit once already, in the first
version of this analysis.

## What it deliberately does not cover

- **Commands that could not be confirmed against the shipping binary**: passive
  mode, ECMP and ECMP rebalance, MSDP, BSR, AutoRP, MLAG, `ip multicast
  boundary oil`. These exist in FRR's YANG model; their CLI syntax was not
  extractable, so they are absent rather than guessed at.
- **IPv6.** `pim6d` ships and is not enabled; no MLD model is written.
- **SSM and MSDP were not exercised.** The verification covered ASM with a
  static RP only.
- **No shorthand for an RP serving all groups.** FRR defaults a bare
  `ip pim rp X` to 224.0.0.0/4, but an implicit form would also silently
  conflict with a per-group entry on the same RP, so the range is written out.
- **No scale or performance testing.** Not possible under QEMU.
- **The FAL offload path is untouched**, consistent with dropping hardware
  support this round.

## Verification of the CLI itself

Offline, without a VM: `parser.py` was run over a configuration exercising all
21 mappings, and every line it produced is valid FRR 10.3 syntax. `pyang`
accepts the configuration module with no warnings at all — every import,
augmentation point and leafref resolves against the real modules. The
operational module produces the same two "imported module not used" warnings
that the existing `op-ldp` and `op-ospf` modules produce, because `pyang` does
not count `opd:augment` as usage.

One detail checked rather than assumed: where an optional argument is absent the
generator leaves a trailing space, as it already does for `redistribute bgp
[route-map ...]`. `frr-reload.py` strips every line as it loads it, so this
cannot produce a spurious diff on each reload.

Not yet done: the generated configuration has not been pushed through a running
router by way of the DANOS CLI. The commands are known good and the translation
is known correct; what remains untested is a `commit` end to end.
