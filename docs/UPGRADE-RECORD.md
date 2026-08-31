# DANOS 2110a to 2608: what the upgrade actually involved

This is the repository-side reference: topology, decisions, and where things
live. The narrative account of the same work — the defects in order, with the
console output and the wrong turns — is kept as a separate published record.
Keep the two consistent when either changes.

DANOS 2110a targets Debian 10. Nothing in that stack is still current, and the
parts DANOS forked have drifted far enough from upstream that carrying the forks
forward costs more than retiring them. This record covers the move to Debian 13,
what broke, and how each break was proved rather than guessed at.

| | 2110a | 2608 |
|---|---|---|
| Debian | 10 buster | 13 trixie |
| Kernel | 5.4 | 6.12 |
| DPDK | 20.11 (DANOS fork) | 24.11 (upstream) |
| FRR | 7.6 | 10.3 |
| liburcu | 0.10.2 | 0.15.2 |
| cloud-init | 18.3-5vyatta9 | 25.1.4-1+deb13u1vyatta4 |

Branch `i-danos/2608` across the source repositories. Release id `2608`, ISO
named `i-danos`.

## Two decisions that shaped everything else

**Upstream first.** Where Debian 13 ships something equivalent, the DANOS fork
is retired rather than rebased. This is why the DPDK fork is gone, and it is
also where most of the real defects came from — see below. The forks were not
carrying cosmetic changes.

**No hardware-vendor support.** The switch-vendor SDK paths, the swport
plumbing, and the vendor FAL plugins are dropped. This is what makes the
Debian 13 move tractable at all; those paths were pinned to old toolchains.

## Repository topology

The official project publishes 189 repositories. Locally they live under
`build-iso/danos-sources/`, with our fork remotes under `github.com/i-danos`.
Two things about this layout are worth knowing before touching it:

- `/home/aikon/danos/build-iso` is a *directory* that happens to share a name
  with the `build-iso` *repository*, which sits at
  `build-iso/danos-sources/build-iso`. Paths in older notes are ambiguous
  because of this.
- In the `tests` repository, `origin` points at the upstream `danos/tests`, not
  at ours. Our remote is `fork`. The `toolkit` repository has only the
  `i-danos` remote. Both `master` branches now track the i-danos side, so a bare
  `git push` goes to the right place; reaching upstream needs an explicit
  `git fetch origin`.

`linux-vyatta` does not follow the branch convention the other repositories
do, and should not be made to. Its `master` is at `2c85ebc5`, "Linux 5.10",
dated 2020-12-13 — vanilla upstream, inherited when the repository was forked
and untouched since. DANOS kernel work lives on series branches:
`linux-vyatta-4.19.y`, `-5.4.y`, `-5.10.y`, `-6.12.y`. Ours is
`i-danos/2608`.

So `git push i-danos HEAD:master` is rejected there as a non-fast-forward, and
that rejection is correct rather than an obstacle to route around: taking it
would replace an upstream release tree with a DANOS 6.12 one and destroy what
the branch means. The consolidation done elsewhere — merge 2608 into master,
retire 2608 — does not transfer to this repository, because master is not its
development line.

`linux-vyatta-6.12.y` is a parallel lineage rather than an ancestor of ours:
its head carries the same subject as our oldest 6.12 commit but a different
hash, so it was rebased or re-created at some point. Nothing depends on
reconciling the two today.

`toolkit/build/build_order.txt` carries 148 active entries. The trailing block
documents 17 repositories that are never built — kept in the tree for reference
but not part of the image. Two redundant entries are commented out rather than
deleted so the reason stays visible.

On OBS (`home:i-danos`), 150 packages: 141 succeeded, 9 disabled, none
unresolvable. Note that `home:` projects on build.opensuse.org are
world-readable, so uploading sources there publishes them.

That tally was wrong for several days in a way the tally itself could not show.
`vyatta-dataplane` and `vyatta-security-vpn` are built locally rather than on
OBS -- the local build skips the queue -- and both package directories had
accumulated more than one `.dsc`. OBS builds one source package per directory
and cannot choose between two, so neither was ever scheduled: uploads
succeeded, the revision climbed to 10, and the packages appeared in no status
column at all. Not failed, not disabled, not unresolvable. Every one of the six
dataplane and VPN defects above had therefore never been compiled on OBS.

It also took five other packages down with it. `owamp`, `td-agent-bit`,
`vplane-config`, `vplane-controller` and `vyatta-interfaces-bonding` all
reported `unresolvable`, because what they link against was never produced.
All five cleared the moment the dataplane built. The visible failures were the
downstream ones; the package actually at fault was the one nothing reported.

`toolkit/build/90-upload_obs.sh` uploads a locally built source package and
deletes the other versions in the same directory, so this cannot recur. To
check for the same class of problem, compare `osc ls` against `osc results` --
a count of 150 against 150 means nothing is stuck outside the scheduler.

The 9 disabled packages were reviewed on 2026-08-30 and all 9 are correctly
disabled. They fall into three groups, none of them hardware-vendor related:

- **Superseded by Debian stock.** `libpcap` — the image installs Debian's
  `libpcap0.8t64` 1.10.5-2, the `t64` suffix marking it as trixie's time64
  build, so the fork is genuinely unused.
- **Build-time only, never in the image.** `check`, `golang-1.15`,
  `golang-dbus`, `golang-defaults`, `golang-golang-x-sys`. Debian 13 supplies
  what the build needs. Also `libvirt` and `host-sflow`, which ship no binary
  into the image at all.
- **A duplicate source.** `vplane-config-npf-alg-scripts` 3.0.1 declares the
  same three binary packages as `vplane-config-npf` 4.5.0 —
  `vyatta-system-alg-v1-yang`, `vyatta-system-alg-routing-instance-v1-yang`,
  `vyatta-op-system-alg-v1-yang`. Only one of the two can be built. The image
  carries all three at 4.5.0, so ALG is complete and it is the older split that
  is disabled; enabling it would put two sources in contention for the same
  binary package names.

Each conclusion is drawn from what the built image actually installs rather
than from the package lists — a package list names a binary package, which says
nothing about who supplied it.

## The defects

Ten defects needed a booted image to find; several needed a booted *topology*.
`DEFECTS.md` covers each in full. The short version, grouped by what caused
them:

**Retiring the DPDK fork (4).** The DANOS fork of DPDK carried functional
patches, not just build fixes, and the first port replaced them with stubs in
`compat.h`. That compiled and looked fine:

- `rte_acl_rcu_qsbr_add` gone meant an ACL trie could be rebuilt while readers
  were still traversing it. Fixed in dataplane 3.14.33 by excluding readers
  across the rebuild.
- `rte_acl_del_rule` and `rte_acl_copy_rules` stubbed out meant deleted rules
  kept matching. Fixed in 3.14.34 by tracking rules per trie and rebuilding the
  context, rather than relying on DPDK to do it.
- DPDK 22.11 merged the crypto session model. `elt_size` of 0 on the symmetric
  session pool made every session allocation fail. Fixed in 3.14.35.
- The separate private session pool the old model needed became redundant and
  actively harmful. Removing it in 3.14.36 took `total-sas` from 0 to 2.

**liburcu 0.15 exposing an old ordering bug (1).** `rldb` tore the database down
before disabling it, a 2021 upstream defect that the older liburcu happened to
tolerate. 2105 survived eight rounds; 2608 crashed on 2 of 2 before the fix and
0 of 4 after. Fixed in 3.14.31.

**Debian 13 unit renames (1).** `strongswan.service` is `strongswan-starter.service`
on Debian 13. The IKE daemon therefore never started, and the commit reported
"succeeded (non-fatal failures)". Fixed in `vyatta-security-vpn` 2.18/2.19,
which also waits for the VICI socket instead of testing for it once.

**Found earlier in the port (4).** Perl `given`/`when` warnings on stdout, the
XFRM policy path never committing its rldb transaction, a `linux-headers-amd64`
version race, and a cloud-init stage deadlock. See `DEFECTS.md`.

## Test suites

All five pass on the 2608 image:

| Suite | Result |
|---|---|
| `danos_restapi` | 21/21 |
| `IPSEC_VPN` | 10/10 |
| `FIREWALL` | 16/16 |
| `BGP` | 16/16 |
| `MPLS_LDP` | 11/11 |

Getting there meant fixing the suites, not the product. Every remaining failure
after the six product defects above turned out to be a stale assertion, a
Debian 10 to 13 tool change, a judgement criterion that is invalid under DPDK,
or a gap in the harness. Three are worth recording because the failure mode
pointed somewhere else entirely:

**MPLS_LDP** asserted that PE1 and PE2 each discover the other. The topology is
`PE1 — P1 — PE2`; link discovery reaches directly connected neighbours only, and
nothing in the suite configures a targeted session. The assertion could not pass
on a working system. The equivalent check on P1 asserts both and passes, which
is what confirmed LDP itself was fine.

**BGP**'s iBGP multihop case left R2's OSPF router-id unset while pinning R1's
and R3's. With no loopback configured on R2 either, ospfd fell back to the
highest interface address — and the surrounding tests add and remove dataplane
addresses, so that address changes. Observed going from `203.1.1.3` to
`202.1.1.3` when the R4 link was torn down. Changing the router-id resets every
adjacency, so the check found the neighbour in `ExStart` with a sub-second
uptime no matter how long the case slept.

**FIREWALL** applied its rulesets to R2 `dp0s9`, the interface carrying the OSPF
adjacency the topology depends on. A DANOS ruleset ends in an implicit drop, so
applying any of them dropped R1's OSPF hellos along with the traffic under test:
R1 sat in `Init/DROther` until the 40s dead interval expired and the route was
withdrawn. Every later case then probed an address it had no path to. Each
ruleset now ends with a catch-all accept, and the suite went from 9/16 to 16/16.

## The harness

`toolkit/vm/` boots QEMU topologies from a built ISO. `boot-topo.sh` takes
`TOPO=fw|ipsec|bgp`; `relays.sh` maps the suites' expected management addresses
onto the QEMU host-forwarded ports through socat containers; `prep-router.sh`
sets up each booted router.

Three things `prep-router.sh` does that are not obvious, each of which cost time
before it did them:

- **Passwordless sudo.** DANOS grants `%vyattasu ALL= ALL` with no NOPASSWD. The
  suites run `sudo ping` and `sudo tcpdump` over a non-interactive session, so
  they hung until vymgmt reported `VyOSError: Connection timed out` — which
  reads like an unreachable router and is not one.
- **telnetd.** The FIREWALL suite's "TELNET allow" case waits for a login prompt
  on port 23. The image ships `inetutils-telnetd` and `vyatta-service-telnet`
  but starts neither.
- **A blackhole route for `172.16.0.0/12`.** Without it, a probe for an address
  the topology has no route to follows the default route into QEMU's user-mode
  stack and out to the build host — where `172.16.1.2` matched
  `via 172.18.0.2 dev singbox_tun`, a proxy that completes a handshake to any
  destination. `nc -vz 172.16.1.2 80` then reported success for an unreachable
  address, and every firewall "block" assertion failed in a way that looked
  exactly like the firewall not enforcing its rules. This one is worth
  emphasising: it produced a completely convincing false defect, and the only
  reason it came apart was that ICMP and TCP disagreed.

Wider variants of that route fix both take management down, ending every login
with `Connection timed out during banner exchange`: deleting the default route
outright, and blackholing `0.0.0.0/1` plus `128.0.0.0/1`. Keep the blackhole
narrow.

## Image

`build-iso/auto/config` names the image from `RECIPEFILE` and the version id:

```sh
: ${RECIPEFILE:="i-danos"}
VERSION_ID=$(get_prjconf_parameter _vyatta_version_id)
IMAGE_NAME="${RECIPEFILE%.livebuild}_${VERSION_ID}_${BUILDSTAMP}"
ISO_VOLUME="${VERSION_ID}"
```

Two live-build traps: `lb config noauto` bypasses `auto/config` entirely and
silently discards the whole DANOS configuration, and `RECIPEFILE` defaults from
`basename $(pwd)`, so the directory name leaks into the image name unless it is
set. The `96-os-release.chroot` hook replaces keys in place via `readlink -f`
rather than appending, so re-running it does not accumulate duplicates.

## Still open

- `DEFECT-npf-acl-classify.md` is kept for its debugging detail; its root cause
  is established and fixed, and its status line now says so.
- The 9 disabled OBS packages have not been revisited.
- `linux-vyatta` is at 6.12.101-1vyatta1, six stable releases behind 6.12.107.

  Reviewed on 2026-08-30: stay on 6.12 and keep importing stable updates. 6.12
  is longterm and not EOL, so there is no reason to change series, and the
  question is only cadence. The import is cheap: 6.12.94 to 6.12.101 on
  2026-08-26 was a single commit over 2157 files with no follow-up fixes, so
  all 55 patches applied clean -- 27 Debian generic in `debian/patches`, 28
  DANOS out-of-tree in `debian/patches-vyatta`. What costs time is the rebuild
  and the re-verification on real hardware, not patch archaeology, and skipping
  imports only makes the next one worse.

  (The DANOS series started at 35 patches; `8816fed6b` dropped the ipmi_ssif
  revert and others went with it, so 28 is the current count.)
