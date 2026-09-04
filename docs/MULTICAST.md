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
| `pimd` / `pim6d` | shipped, not enabled | in `frr 10.3-3+deb13u1`; `etc/frr/daemons.danos` is an allowlist and listed only bgpd, isisd, ospfd, ospf6d, ldpd — a daemon not named simply does not start |
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

`vyatta-protocols-frr` 1.16.0. No C and no translation code: the config-to-FRR
layer in this package is a declarative path map, so a protocol is a JSON file
plus YANG.

```
protocols pim
  rp <address> group <prefix>          rp <address> prefix-list <name>
  keep-alive-timer                     rp-keep-alive-timer
  register-suppress-time               join-prune-interval
  packets                              ssm prefix-list <name>
  ssmpingd <address>
  spt-switchover infinity-and-beyond [prefix-list <name>]
  bsr candidate-bsr    [priority] [address|interface|loopback|any]
  bsr candidate-rp     [priority] [interval] [address|...] group <prefix>
  autorp discovery
  autorp announce      rp-address <addr> group <prefix> | group-list <name>
                       [scope] [interval] [holdtime]
  autorp send-rp-discovery  [address|...] [scope] [interval] [holdtime]
  msdp peer <addr>     source-address  password  sa-limit  sa-filter in|out
  msdp mesh-group <n>  source-address  member <addr>
  msdp timers keep-alive <s> hold-time <s> [connection-retry <s>]
  msdp originator-id   msdp shutdown   msdp log neighbor-events|sa-events

protocols pim6
  rp / prefix-list / keep-alive-timer / rp-keep-alive-timer
  join-prune-interval / packets / register-suppress-time / ssmpingd
  spt-switchover infinity-and-beyond [prefix-list <name>]
  bsr candidate-bsr / candidate-rp     (as above, IPv6 addresses)
  embedded-rp [group-list <name>] [limit <n>]

interfaces <type> <name> ip pim
  hello-interval / hello-holdtime      dr-priority      use-source
  passive     bsm     unicast-bsm      active-active

interfaces <type> <name> ip igmp
  version                              query-interval
  query-max-response-time              last-member-query-count
  last-member-query-interval
  join-group <group> [source <src>]    static-group <group> [source <src>]

interfaces <type> <name> ipv6 pim
  hello-interval / hello-holdtime      dr-priority
  passive     bsm     unicast-bsm      active-active

interfaces <type> <name> ipv6 mld
  version / query-interval / query-max-response-time
  last-member-query-count / last-member-query-interval
  join-group <group> [source <src>]    static-group <group> [source <src>]
```

Operational commands sit under `show protocols pim`, `show protocols igmp`,
`show protocols msdp`, `show protocols pim6` and `show protocols mld` — 63 in
total.

Every generated command was extracted from the shipping daemon, by entering the
`router pim` or `router pim6` node in `vtysh` and running `list`. The `frr`
repository in `danos-sources` is the retired 7.6 fork and is **not** what the
image installs — reading daemon lists or command syntax out of it gives answers
about software that is not there. This bit once already, in the first version
of this analysis.

### IPv6 is not a mirror of IPv4

`pim6d` has no MSDP and no Auto-RP. An IPv6 domain learns about out-of-domain
sources through **embedded RP**, where the RP address is carried inside the
group address itself, rather than through RPs telling each other. It also has
no `ssm prefix-list`, no ECMP controls and no `rpf-lookup-mode`. Modelling it
as a copy of the IPv4 module would have invented commands that do not exist,
so it is a separate module that follows the daemon.

### The generated form is a `router pim` block

FRR keeps top-level `ip pim ...` as a compatibility alias for the older subset
only. BSR, Auto-RP and MSDP exist solely inside the `router pim` node. Feeding
the generated lines to the shipping FRR made that unambiguous: 25 of 38
rejected as unknown commands, every one of them a new feature, while the old
ones passed.

Emitting a block also removed a form mismatch that predated this work — FRR
normalises a flat `ip pim rp` into a `router pim` block, so the generated file
never matched the running configuration. It reloaded without churn either way
(PIM neighbour uptime is continuous across a commit that rewrites `frr.conf`),
but the two now agree.

## What it deliberately does not cover

- **IPv4 commands still absent**: ECMP and ECMP rebalance, `register-accept-list`,
  `rpf-lookup-mode`, `ip pim bfd`, `ip igmp proxy`, `ip multicast boundary`.
  Each needs its own thought — the boundary commands take ACL references — and
  none is part of the four areas this round set out to cover.
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

## End to end, through the CLI

Done on the three-router topology with 1.16.0 installed on the running LIVE
image, configured only through `set` and `commit` — no `vtysh` anywhere.

`commit` generates, on R3:

```
interface dp0s9
ip igmp
ip igmp join-group 239.1.1.1
ip igmp query-interval 125
ip pim
...
ip pim rp 2.2.2.2 224.0.0.0/4
```

PIM neighbours came up on both of R2's interfaces, R2 was elected RP (ASM,
Static), R3 joined 239.1.1.1 on `dp0s9`, and R2 built `(*, 239.1.1.1)`. 5000
datagrams later:

```
R2  dp0s9   in 4997  ->  dp0s10  out 4997
R3  dp0s10  in 4997  ->  dp0s9   out 4997
```

`(S,G)` reads `fast/dataplane` on both. The three lost packets are the ones
ahead of the MFC entry.

### Three silent failures, in the order they were hit

None of them logs anything.

**1. The module was not registered with the VCI component.** `Modules=` in
`debian/vyatta-frr-vci.component` is an explicit list of the YANG modules whose
configuration configd hands to the FRR VCI. A module missing from it is never
delivered, so the translation step does not run. The CLI accepts every command,
`cli-shell-api showCfg` reads the configuration back correctly, `commit` reports
success — and `frr.conf` contains no PIM lines at all. This is the expensive one:
every observable surface says the feature works.

**2. Installing the package stops FRR.** The postinst stops
`vyatta-routing-frr-early.target`, which systemd refuses
(`RefuseManualStop`), and FRR is left down. Every subsequent commit then fails
its reload with `vtysh: failed to connect to any daemons`. Pre-existing
behaviour, not introduced here, but it makes an in-place upgrade look like a
broken package.

**3. A commit with nothing to commit regenerates nothing.** Re-running the same
`set` commands after they are already in the configuration yields "Node exists"
for each and "No configuration changes to commit" — so `frr.conf` is never
rewritten. If a previous run left the configuration in place but the file stale,
only `delete` then `set` forces the regeneration.

### Operational commands: FRR verified, CLI not verifiable this way

All 24 commands the op YANG defines were walked, checking two things separately
because one masks the other — whether the CLI resolves the path, and whether FRR
accepts the underlying `vtysh` command.

**FRR side: 24 of 24.** Every command exists in FRR 10.3 and returned real data
from the running routers. This is the half most likely to be wrong, since the
syntax was written against 10.3 without all of it being exercised, and it is now
settled.

**CLI side: 0 of 24**, all `Invalid command: show protocols [pim]`, and this is
not evidence about the module. A control experiment settles it: injecting a
throwaway command into the *shipping, working* `vyatta-op-protocols-frr-ldp-v1`
module and restarting configd does not make it appear either —
`show protocols mpls-ldp` keeps exactly its original children. Operational
commands from a package installed after boot do not enter the op tree, whatever
module they come from.

Ruled out along the way: the augment point (`show protocols ospf neighbor`
works), packaging (both op packages install one file to the same directory, with
no maintainer scripts), module structure, brace balance, unescaped quotes in
description strings, `configd -yangdir` (defaults to exactly that directory),
and restarting the VCI bus as well as configd. Nothing is logged at any point.

The instrument that finally gave a straight answer is `opc -op=children <path>`,
which lists what the op tree actually contains. Note that
`cli-shell-api getTmplChildren` is *not* that instrument — it returns
`Invalid operation`.

So the op CLI has to be verified with the package present at boot, which means
built into the image.

**Verified on an image carrying 1.16.0: 24 of 24, both sides.** `opc -op=children
show protocols` returns `bgp igmp isis mpls-ldp ospf ospfv3 pim`, and with the
topology configured through the CLI the commands render live state:

```
show protocols pim neighbor      dp0s9 65.1.1.2 / dp0s10 66.1.1.2
show protocols pim rp-info       2.2.2.2  224.0.0.0/4  lo1  yes  Static  ASM
show protocols pim mroute count  65.1.1.2  239.1.1.1  5000 packets  1140000 bytes
show protocols igmp groups       dp0s9  239.1.1.1  EXCL  3 groups total
```

`WrongIf` on that entry reads 2, not 0 — two packets arrived on an unexpected
interface while RPF was still settling. Expected during convergence, recorded
because it is not zero.

Getting there took two more rebuilds, both of which produced a clean image with
`exit=0` and no error:

- The repository HTTP server on 8080 was started a minute after `lb build` ran
  its `apt update`. Every DANOS package came back `Unable to locate` — 850 of
  them — and the failure is only visible in `build_test.log`, not in the build
  script's own output, which reported `exit=123` with no error text.
- The image installs a curated package list, not the contents of the
  repository. Adding the packages to the repository and reindexing left the ISO
  with every other 1.16.0 binary and neither PIM package. They have to be named
  in `config/package-lists/vyatta-yang-protocols-frr.list.chroot`.

### Two wrong readings during the diagnosis

Both were a probe that had never been checked, taken as a result.

`cli-shell-api getTmplChildren protocols` was used to ask whether the `pim` node
existed. It returns `Invalid operation` — it was never answering the question,
and its empty output was read as "the node is missing".

Separately, `Configuration path: ... is not valid` alongside `Node exists` was
read as the whole configuration tree having failed, when it means the node was
already set. `showCfg` showed the configuration sitting there correctly the
whole time.

The pattern is the same one this port produced repeatedly: an unverified
instrument returning something that looks like a product defect.

## Second round: BSR, Auto-RP, MSDP, SSM and IPv6

The features left out the first time, because their syntax "could not be
confirmed". It could: the answer was in the running daemon the whole time.

### Verified as configuration

`parser.py` over a configuration exercising every mapping, then every generated
line fed to the shipping FRR:

| | mappings | FRR accepted |
|---|---|---|
| IPv4, with BSR / Auto-RP / MSDP / SSM | 52 | 38 of 38 |
| IPv6, PIM6 / MLD / embedded RP / BSR | 34 | 30 of 30 |

Then on an image carrying the packages, configured only through `set` and
`commit`: `pim6d` starts by itself, the operational tree gains `pim6`, `mld`
and `msdp`, and all 63 operational commands resolve.

### Verified as protocol

Configuration generating correctly is not the protocol running. Both ends were
configured on the three-router topology so each protocol had someone to talk
to:

| | evidence |
|---|---|
| BSR | R2 elected (`Elected: Yes`), R3 learned it (`ACCEPT_PREFERRED`) and picked up the candidate RP through it — R3's RP table reads `Source: BSR`, not Static |
| MSDP | `established` on both ends |
| IPv6 PIM | adjacency up on both ends of the R2–R3 link |
| MLD | `ff0e::1 JOIN` registered, and PIM6 built `(*, ff0e::1)` with an outgoing list |
| SSM | `show ip pim group-type` reports the configured range in place of the 232.0.0.0/8 default |

### Not verified

- **Auto-RP.** Configuration generates and FRR reports discovery and
  announcement enabled, but no RP was ever discovered through it (`count=0`);
  a mapping agent and a second announcing router were never set up.
- **No multicast traffic was forwarded over any of this.** The first round
  proved the dataplane with counters; this round stops at protocol state. An
  SSM forwarding test and an IPv6 forwarding test are both still open.
- **embedded RP** was configured, never exercised.
- **MSDP SA exchange.** The session establishes; no source was ever advertised
  across it (`SaCnt 0`).

### Four false failures, all of them the test

Each of these looked like a broken feature and none was.

**The whole commit failed on a dangling reference.** `ssm prefix-list SSM-RANGE`
was set without creating the prefix list. The leafref rejected it and took the
entire R2 commit with it, so nothing on R2 was configured — and BSR electing
nothing, MSDP sitting one-sided and zero IPv6 neighbours all followed from
that. The model did exactly its job; the reading of the result was what went
wrong.

**`ipv6 address` does not exist.** Addresses of both families go under the
interface's single `address` node; the `ipv6` node carries protocol
configuration only.

**MSDP left over the management interface.** The peers are loopbacks, as MSDP
is normally deployed, and OSPF had not been configured on one end. Without a
route the TCP session goes out `ens31` into QEMU's user-mode stack and stays in
`connecting` forever. Same shape as the default-route trap in
`prep-router.sh`, in a new place.

**`candidate-bsr source address X` is not the CLI path.** The YANG models the
four alternatives as a `choice`, and a choice and its cases are transparent in
the data tree, so the node is `address`: `set protocols pim bsr candidate-bsr
address 2.2.2.2`. FRR's own syntax has the `source` keyword and the generated
line carries it — `bsr candidate-bsr priority 200 source address 2.2.2.2` — but
the CLI does not. Configured the wrong way the command is rejected while
`priority` still applies, so the router reports a candidate BSR with
`Address: 0.0.0.0` that never wins an election. That reads as BSR being broken.

### Two things FRR does that look like defects

**Defaults are not written back.** `bsr candidate-bsr priority 64`,
`msdp timers 60 75` and pim6 `keep-alive-timer 210` are all FRR defaults, so
they are accepted and then absent from `show running-config`. The generated
file and the running configuration differ by exactly those lines.

**Auto-RP state is not written back at all.** A commit that enables discovery
and announcement leaves no trace in `show running-config`. `show protocols pim
autorp` is the only way to see it took, which is why that command exists.

**`ssmpingd` ignores a loopback address.** `ssmpingd 2.2.2.2`, where 2.2.2.2 is
on `lo1`, produces no entry and no log line; `ssmpingd 65.1.1.3` and
`ssmpingd 0.0.0.0` both log `starting ssmpingd for source ...` and appear in
`show ip ssmpingd`. The generated command is correct either way — this is FRR's
behaviour, recorded so it is not rediscovered as a CLI fault.

### Scripts

`toolkit/vm/` carries three, replacing eight one-off generations:

```
config-multicast.sh           configure every node through set and commit
verify-multicast-cli.sh       walk every operational command
verify-multicast-protocol.sh  configure both ends, check the protocols run
```

`verify-multicast-cli.sh` derives its command list from the op YANG rather than
from a list generated beside it. A checked-in list goes stale the moment a
command is added, and it fails silently — the walk passes because it never
tried the new command. Derived, it went from 24 commands to 63.
