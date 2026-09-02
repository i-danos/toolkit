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

Branch `i-danos/2608` across the source repositories, with one exception:
`linux-vyatta` uses `linux-vyatta-6.12.y`, following that repository's own
kernel-line convention. Release id `2608`, ISO named `i-danos`.

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
and untouched since. DANOS kernel work lives on series branches named for the
kernel line, and ours now sits on the one that matches it:
`linux-vyatta-4.19.y`, `-5.4.y`, `-5.10.y`, `-6.12.y`.

It was on `i-danos/2608` for most of the port, alongside a separate
`linux-vyatta-6.12.y` holding an earlier 6.12.94 import and a `danos/2110b`
holding a parallel one. All three were reconciled on 2026-09-02: our line was
renamed to `linux-vyatta-6.12.y` and the other two branches deleted. Nothing
was lost. `i-danos/2608` was the same commit as the renamed branch, and
`danos/2110b`, which shared no ancestor with ours, turned out to carry the same
*content* — its tip tree and ours at the 6.12.94 point are both `dd0191df4c24`,
with an identical `patches-vyatta/series` — so the two were the same rebase
recorded as two histories, and ours is the one that continued to 6.12.107. The
deleted commits included `e5e0e4117`, which the old `linux-vyatta-6.12.y` and
`danos/2110b` both carried; deleting one of them alone would not have lost it,
which is only visible if you check both before deleting either.

The branch that matches OBS is `linux-vyatta-6.12.y`, and matching was verified
by content rather than by version string: the `netdevice-stats-override.patch`
in the source package OBS built hashes to `0ed601dc53e73d41fde6f795`, and so
does the one on that branch. Two branches can carry the same changelog version
and different trees, which is exactly what the old 6.12.y did.

So `git push i-danos HEAD:master` is rejected there as a non-fast-forward, and
that rejection is correct rather than an obstacle to route around: taking it
would replace an upstream release tree with a DANOS 6.12 one and destroy what
the branch means. The consolidation done elsewhere — merge 2608 into master,
retire 2608 — does not transfer to this repository, because master is not its
development line.

Our 6.12 line descends from the 2110a baseline logically but not
genealogically, and the distinction matters when reading the history.
`danos/2110a` is a **tag**, not a branch, on `ee3324762` — "Update changelog
for 5.4.149-0vyatta1 release", 2021-09-27, which is also the head of
`linux-vyatta-5.4.y`. Commit `f525c0cab` records what was done to it:
"the overall Debian 10->13 / kernel 5.4.149->6.12.94 rebase". A rebase across
kernel versions replaces the source outright and re-targets the patches, so
no commit on the remote is a git ancestor of ours — `ee3324762` included.
Expect `git merge-base` to say no and do not read that as the baseline being
wrong.

The old `linux-vyatta-6.12.y` was likewise a parallel lineage: its head carried
the same subject as one of our 6.12 commits but a different hash. That is what
the reconciliation above resolved.

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

## The CLI sandbox: why it was off, and what it actually was

Booting official DANOS 2105, live or installed, lands a login in a vbash shell
inside a per-user sandbox. 2608 now does the same. It did not for most of the
port, and the reason recorded here was wrong, so the whole line is worth
keeping.

`build-iso/config/hooks/live/50-disable-user-isolation.chroot` used to run
`pam-auth-update --package --remove sandbox` and delete
`/usr/share/pam-configs/sandbox`, leaving `/etc/pam.d/common-session` without
the `pam_sandbox.so` line 2105 has. Its stated reason was that `pam_sandbox`
does not work on trixie: that it asks systemd-machined for a per-user
`systemd-nspawn` container, that this fails under systemd 257 / kernel 6.12,
and that the module being `required` then refuses the session -- so the choice
was "no sandbox or no login".

**The module never failed.** It succeeds on every login and says so:

    login[4368]: pam_sandbox(login:session): tmpuser login entering sandbox cli-1000(leader=3002)

and `machinectl` shows `cli-1000` running under `cli-sandbox@tmpuser.service`,
created at boot, before anyone logs in. What failed was the step after: `login`
carries on with the terminal it was started on and refers to it by name, and
util-linux 2.41 needs that node to exist under the new root. systemd-nspawn
builds the container's `/dev` from a fixed minimal list with no tty in it.
Official 2105's sandbox has exactly the same `/dev` -- also no `ttyS0`, no
`tty1` -- and works, because buster's util-linux 2.33 did not need one. The
difference is util-linux, not configuration and not the sandbox.

The symptom carries none of that. The session opens, the MOTD prints, the shell
exits, `login` exits, autologin respawns; `getty@tty1` had restarted 282 times
on the image this was found on, and the console echoed keystrokes while
answering nothing -- the tty line discipline still there, the shell that would
read it gone.

`cli-sandbox` 0.27 binds the nodes in a `sandbox-post-create.d` hook, the
extension point `vyatta-sssd-cli-sandbox` already uses: it appends `Bind=` for
the ttys systemd's getty units actually have to the per-sandbox
`/run/systemd/nspawn/<machine>.nspawn`. pts needs no help -- `/dev/pts` is
already in the container, which is why ssh sessions were never affected and
only the console was. With that in, the disable hook is gone and the image
boots into the workspace on both paths:

| | LIVE | installed |
|---|---|---|
| boot | one login prompt, no getty loop | same |
| session | `tmpuser@node:~$` | `tmpuser@node:~$` |
| sandbox | `vbash-sandbox:` prefix | `vbash-sandbox:` prefix |
| operational CLI | works | works |
| restricted commands | `ifconfig`, `insmod` unreachable | same |
| `show version` | `Boot via: livecd` | `Boot via: image` |

Turning it off is still supported and now goes through DANOS's own switch,
`system login user-isolation disable`, which can also put the profile back from
`/opt/vyatta/share/pam-configs/sandbox` -- something a build-time deletion
cannot.

Three things about the shape of this are worth keeping.

**The package being installed proves nothing.** `pam-sandbox` is `install ok
installed`, `pam_sandbox.so` is on disk, and a login can still land outside the
sandbox, because whether the module is *called* is decided by `pam-auth-update`
and lives in `/etc/pam.d/`. A package manifest cannot see it;
`toolkit/vm/verify-workspace.sh` checks pieces, wiring and behaviour
separately for that reason.

**Superuser sessions are exempt by design.** `pam_sandbox.c`'s
`exclude_groups` is `{ "vyattasu", NULL }`, so a `level superuser` account is
never sandboxed. A first attempt to measure the sandbox used such an account,
got `systemd-detect-virt -c` = `none`, and read it as the sandbox not working.
It also means the test suites are unaffected: they log in as `vyatta`, a
superuser, and get a full shell.

**Inside the sandbox, shell-level inspection is gone.** `[Network] Private=yes`
gives the container its own netns, so `/sys/class/net` shows only `lo`;
`systemctl` reports "System has not been booted with systemd as init system",
the container's PID 1 being `cli_sandbox_init`; `ip`, `sudo` and `vplsh` are
not on the path. Verification has to go through the CLI, whose configd and opd
sockets are bind-mounted in. Harness steps written against the sandbox-off
image do not survive this -- see `toolkit/vm/prep-router.sh`.

## Test suites

All five pass on the 2608 image, and were re-run in full after the CLI sandbox
was restored -- 74 cases, same scores, no regression from booting into the
workspace:

| Suite | Result | Topology |
|---|---|---|
| `danos_restapi` | 21/21 | `TOPO=bgp` + `restclient.sh` |
| `IPSEC_VPN` | 10/10 | `TOPO=ipsec` |
| `FIREWALL` | 16/16 | `TOPO=fw` |
| `BGP` | 16/16 | `TOPO=bgp` |
| `MPLS_LDP` | 11/11 | `TOPO=ipsec` |

The topology column is not decoration. Three of the five need wiring the other
two do not have, and a mismatch fails as product symptoms -- empty OSPF
neighbour tables, 100% ping loss, a tunnel that never comes up. IPSEC_VPN
scored 5 of 10 twice on the FIREWALL wiring, the second time on a freshly
booted topology to rule out leftover state, before the slots were read off the
suite's own test data. On `TOPO=ipsec`, unchanged image and unchanged routers:
10 of 10.

The suites were also run against a system installed to disk, not just the live
image -- 74 of 74, same scores. That path had only ever been verified as far as
booting into the workspace, and it differs where this port's last defect was:
the sandbox container's root is carved from the running root filesystem, ext4
on a block device here and squashfs plus an overlay on live. One install was
enough for all of it: four qcow2 backing-file clones off a single installed
image, a few hundred KB each, re-wired between suites by restarting the VMs.
That trick costs a shared machine-id and shared ssh host keys, which nothing
here depends on but a DHCP-identity or certificate case would.

Getting there meant fixing the suites, not the product. Every remaining failure
after the six product defects above turned out to be a stale assertion, a
Debian 10 to 13 tool change, a judgement criterion that is invalid under DPDK,
or a gap in the harness. Four are worth recording because the failure mode
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

**BGP**'s `Route Reflector Rule-1` configured all four routers and then checked
the reflected prefix 0.06 seconds after the last `SetCommand`, with no wait at
all -- the whole case ran in 6.3 seconds, of which about 6 were the four
configuration steps. BGP has not brought its sessions up by then, so the table
is empty and the check reads `No BGP prefixes displayed, 0 exist`. `Validate
Next-hop attribute` reuses that configuration, so the two always failed
together, and on one run `Verify local preference` joined them.

It reproduces, which is what made it look like a functional break rather than a
race -- a reproducible race is still a race; on a slower box it simply loses
every time. Two things settled it: the table was empty rather than wrong, and
every later case passed, including ones that exercise the same reflector. Those
cases get away with `Sleep 5` because they reconverge an established mesh;
Rule-1 builds the sessions from nothing and had no wait of any kind. It now
polls with `Wait Until Keyword Succeeds`, which costs nothing once converged.

Worth noting how close this came to the wrong conclusion. It appeared only on
the installed-disk run, where the live run had passed 16/16 -- one run, which
says the race was won once, not that live is immune. Memory was the obvious
suspect, since the four VMs had been dropped to 2560M to fit; raising them back
to 3072M made it worse (3 failures, not 2), which is what ruled memory out.

## What "verified" covers, and what it does not

Everything in this record was verified under QEMU/KVM. No part of it has run on
physical hardware. Where the text says "on hardware", read "on a booted image in
a VM" -- it means a real boot of a real ISO rather than a container or a unit
test, not a physical machine.

The gap that leaves is specific rather than general. The dataplane is DPDK, and
under QEMU it drives virtio-net through the virtio PMD, with hugepages and CPU
isolation as the harness happens to set them. A physical box brings a different
PMD, real NIC queues and offloads, IOMMU and VFIO binding, NUMA placement, and
link events that come from a cable rather than a socket netdev. None of that is
exercised here. Two of this port's defects -- the crypto session pool sized to
zero, and the ACL trie rebuilt underneath live readers -- are the kind that
depend on how the forwarding path is actually driven, and both were found under
QEMU; that says the harness is capable of finding such things, not that it
finds all of them.

Also not covered: the switch-vendor paths, deliberately, since hardware-vendor
support was dropped for this port; and anything about thermals, PSUs, sensors
or platform management, which the image still carries YANG for.

What QEMU does cover is everything above the driver: the CLI, configd, the YANG
model, the routing protocols, the firewall and IPsec paths, the QoS scheduler's
own logic, the sandbox, both boot paths, and the whole package and image build.
That is where this port's work was, and where all ten recorded defects were.

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

## The 9 disabled OBS packages

Re-checked on 2026-09-02. All 9 stay disabled, and none of them needs deleting
from OBS or from the local repository.

Checked three ways rather than by re-reading the reasons:

**In the image.** None of the 9, and none of their binaries, is in the finished
image. `libpcap` in particular is Debian's `libpcap0.8t64` 1.10.5-2, not the
2016 fork.

**In the local repository.** Nothing to do: a disabled package produces no
binaries, and the repository is assembled from OBS's published index, so they
have never been in it. The three ALG yang packages that `vplane-config-npf-alg-
scripts` would also have produced carry `Source: vplane-config-npf` — the right
one won.

**In OBS's dependency graph.** Six are referenced by nothing at all: both golang
bootstrap halves, `host-sflow`, `libpcap`, `libvirt`,
`vplane-config-npf-alg-scripts`. Three are still referenced, and Debian trixie
satisfies each:

| Binary | Consumers in OBS | Debian trixie |
|---|---|---|
| `check` | `vyatta-dataplane-dev` | 0.15.2-3 |
| `golang-dbus-dev` | `config`, `vci`, `yangd`, +1 | 5.1.0-1 |
| `golang-golang-x-sys-dev` | `genetlink`, `netlink` | 0.22.0-1 |

The versions clear the constraints the disable notes cite: `vci` wants
`golang-dbus-dev >= 4.0.0~git20160605` and Debian's 5.1.0 satisfies it, while
the 2017 fork at 4.0.0 is *below* the 5.0.4 that Debian's
`golang-github-coreos-go-systemd-dev` demands — which is why keeping the fork
made the whole Go chain unresolvable. The other two consumers carry no version
constraint.

They stay in OBS rather than being deleted. The disabled state carries the
reason in each package's `_meta` description, and those descriptions are
specific enough to be checkable — `libpcap`'s records that the fork dropped
Debian's soname patch, so `dpkg-gensymbols` fails on `libpcap.so.1` against a
symbols file naming `libpcap.so.0.8`. Deleting the package deletes that, and an
absence with no record invites the same investigation again. The cost of
keeping is zero: a disabled package takes no build capacity, produces no
binaries, and reaches neither the index nor the image.
`vplane-config-npf-alg-scripts` is the one to keep most deliberately — it is
disabled to *prevent* a downgrade, since its 3.0.1 would take the index from
`vplane-config-npf`'s 4.5.0, and a package sitting there disabled with a note
is a better guard than one that is simply gone.

One method note, because the first attempt got the right answer for no reason.
The dependency scan initially read the index from download.opensuse.org, which
returned an empty body; the script reported every package as present in nothing
and depended on by nothing, which happens to be the conclusion. Re-run against
the verified local `.Packages.src` (823 entries), three of the nine turned out
to still be referenced. `curl -s` hides the failure and downstream code treats
empty input as an answer — the same shape as the CDN empty response that made
`cli-sandbox` look unpublished earlier in this round.

## Still open

- `DEFECT-npf-acl-classify.md` is kept for its debugging detail; its root cause
  is established and fixed, and its status line now says so.
- The 9 disabled OBS packages were re-checked on 2026-09-02, after the kernel
  and three package bumps this round, and all 9 stay disabled. See below.
- `linux-vyatta` was at 6.12.101-1vyatta1, six stable releases behind. Imported
  to 6.12.107-1vyatta1, built on OBS and verified on a booted image; the note
  is kept for the cadence decision.

  Reviewed on 2026-08-30: stay on 6.12 and keep importing stable updates. 6.12
  is longterm and not EOL, so there is no reason to change series, and the
  question is only cadence. The import is cheap: 6.12.94 to 6.12.101 on
  2026-08-26 was a single commit over 2157 files with no follow-up fixes, so
  all 55 patches applied clean -- 27 Debian generic in `debian/patches`, 28
  DANOS out-of-tree in `debian/patches-vyatta`. What costs time is the rebuild
  and the re-verification on a booted image, not patch archaeology, and skipping
  imports only makes the next one worse.

  (The DANOS series started at 35 patches; `8816fed6b` dropped the ipmi_ssif
  revert and others went with it, so 28 is the current count.)
