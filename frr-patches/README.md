# Downstream patch for Debian's FRR: do not reuse a nexthop group that holds an inactive member

## What it fixes

On a link failure FRR's zebra can leave the **kernel** route pointing at an equal-cost nexthop group
that still contains the failed port's next hop, for 18-62 s (observed). Flows whose (source, destination)
address pair hashes to that member are blackholed; forwarded traffic is not affected because the data
plane's own table is right. Full evidence and the log walk-through are in `../docs/DEFECTS.md`, the
sections dated 2026-10-04 and 2026-10-05.

Cause, from zebra's debug log: when the local interface-down event reaches zebra before ospfd's route
update, zebra installs the old two-member group, then `zebra_nhg_rib_compare_old_nhe()` /
`zebra_nhg_nexthop_compare()` find the new route's active next hops equal to the old group's active
next hops (the inactive old member is skipped) and **reuse the old group**, so nothing is pushed to the
kernel.

## The change

In `zebra_nhg_nexthop_compare()` (`zebra/zebra_nhg.c`): when an old member is inactive and the new route
does not carry it, the old nhe is no longer considered the same. The trailing-member case at the end
of the function is handled the same way. A persistently inactive member that both old and new carry is
still skipped as before (that case exists in 10.7.1; 10.3 gains it with this patch).

Two files because the function differs: `...-10.3.patch` applies to Debian `frr 10.3-3+deb13u1`
(uses `nexthop_same`), `...-10.7.1.patch` to upstream 10.7.1 (uses `nexthop_same_no_ifindex`).

## Evidence (R2 on the physical J1900 bench, R1 on 10.3; link failed from R1 with `ip link set`)

| FRR on R2 | Failovers where the kernel kept the dead member |
|---|---|
| 10.3-3+deb13u1 | 10 of 19 |
| 10.7.1-2 | 8 of 12 |
| 10.7.1-2 + patch | 0 of 12 |
| 10.3-3+deb13u1danos1 (10.3 + patch) | 0 of 12 |

Upgrading to 10.7.1 alone does not help: it fixes a second defect (a dead singleton being re-validated,
`zebra_nhg_check_valid` / `zebra_nhg_set_valid_if_active`) but the kernel group is still never rewritten.

## What was NOT tested

- The full Robot regression (81 cases) on a build with this patch; only the failover loop above, OSPF/BGP
  adjacency and DANOS CLI commits, and data plane route lookups were exercised.
- Cable pulls (the evidence uses a link taken down from the peer; the patched side is the peer that sees a
  real link loss).
- Any other FRR protocol daemons' behaviour; the change touches only nexthop-group reuse in zebra.
- Whether upstream has a different fix, or accepted this one. Nothing was submitted upstream.
- Side effects of not reusing a group when an inactive member is present: more nexthop-group entries
  are created in that situation; not measured.

## Building

`build-frr-10.3-patched.sh` runs inside a `debian:13-slim` container with `--network host`, with the Debian
`.dsc`, `.debian.tar.xz` and `.orig.tar.xz` for 10.3-3+deb13u1 in a `frr103/` directory next to it, and the patch
in the same directory, mounted at `/work`:

    docker run --rm --network host -v $PWD:/work debian:13-slim bash /work/build-frr-10.3-patched.sh

It produces `frr_10.3-3+deb13u1danos1_amd64.deb`, `frr-pythontools_...`, `frr-snmp_...`. Packages built this way
were installed on a router with plain `dpkg -i` (no forced breaks; the 10.7.1 rebuild needed `--force-breaks`
because Debian sid's packaging declares `Breaks: systemd (<< 259)`).

## Shipping it (state on 2026-10-05)

The patched source package is `frr 10.3-3+deb13u1danos1` (Debian's source with this patch as a quilt patch and
`libyang-dev (>= 2.1.128)` in Build-Depends). It is an OBS package in `home:i-danos` and builds green, in the
**`2608-debian`** repository, not in `2608`:

- OBS resolves a build dependency by name to the first repository in the path that has it, and a project's own
  repository always comes first. DANOS's libyang builds a package named `libyang-dev` (1.0.184), so a
  build-depends on `libyang-dev` always gets it, even with a version constraint; Debian's 3.12.2 is invisible
  (OBS reports "nothing provides libyang-dev >= 2.1.128 (got version 1.0.184-2)"). `2608-debian` has only
  `Debian:13` in its path. It is disabled for every package in `toolkit/obs/project-meta.xml` and enabled for
  `frr` by `upload.sh`, which also disables `frr` in `2608` (`DEBIAN_REPO_PKGS`).
- `close-the-loop.sh` expects `frr` to be green in `2608-debian`, fetches its binaries from there, and fails
  if the ISO's package list does not show a `danos` frr (so the ISO cannot quietly fall back to Debian's).
- The OBS build log shows the patch applied (`dpkg-source: info: applying danos-zebra-nhg-...patch`) and
  `libyang-dev-3.12.2-1` used.

## Keeping it

- **Correction (2026-11-07).** This paragraph used to say the ISO's apt preference (`config/archives/danos.pref.chroot`: `Pin: release o=DANOS`,
  priority 1000) keeps a later Debian `10.3-3+deb13u2` from replacing this package. That holds only for a repository whose `Release` file says
  `Origin: DANOS`. The local overlay's `Release` (written by `reindex-overlay.sh`) has `Codename` and `Suite` only, so for packages shipped through
  the overlay the pin matches nothing and the patched frr is chosen only because `10.3-3+deb13u1danos1` sorts above `10.3-3+deb13u1`. Tested with apt
  in a container configured like the ISO build (`acceptance-p05/frr-nhg-20261106/logs/apt-selection.txt`): with the real overlay apt picks the danos
  version; with a synthetic `10.3-3+deb13u2` added the candidate flips to the Debian one (and installing the three frr packages together fails);
  with `Origin: DANOS` added to the overlay's `Release` the pin applies (priority 1000) and the danos version stays. Not changed here: adding the
  `Origin` line would pin every overlay package, which is a decision for the owner; a pin file for frr alone is the narrower alternative.
  A Debian security update to frr is therefore either silently preferred (overlay without Origin) or not picked up automatically (with the pin):
  when Debian publishes one, rebase: fetch the new `.dsc`, `.debian.tar.xz`, `.orig.tar.xz`, re-apply the patch (check that
  `zebra_nhg_nexthop_compare()` still has the same shape), bump the version to `...danos2`, and rebuild.
- If Debian moves to a newer FRR that already fixes `zebra_nhg_nexthop_compare()`, drop the patch (and
  `frr` from `DEBIAN_REPO_PKGS`, `EXTRA_PKGS` and the allowlist) and test with the failover loop first.

## QEMU A/B, same image (2026-11-07)

Stock `frr 10.3-3+deb13u1` against `10.3-3+deb13u1danos1` on the same test image (`i-danos_2608_20261106T0249`), three routers, two parallel links
between r1 and r2 (`toolkit/vm/boot-topo.sh` TOPO=nhg), the link cut at both ends at once, 20 cuts per side (blocks ABAB), 75 s down, 8 source
addresses per flow family. Every number is recomputed from the raw files by `toolkit/vm/frr-nhg-ab.py analyze`; method, verification of which zebra
binary was running (sha256 of /proc/PID/exe) and all caveats are in `acceptance-p05/frr-nhg-20261106/report.md`.

| | stock | patched |
|---|---|---|
| runs in which the kernel route kept the dead member until the link came back (>5 s) | 20 of 20 | 0 of 20 |
| kernel route left the dead member, per router and run | never within 75.5 s (40 of 40) | median 0.39 s, max 0.54 s |
| router-originated flows, worst silence per run | median 33 s, max 45 s | median 0.59 s, max 0.64 s |
| forwarded-only flow (one-way UDP, 6 runs each) | worst 0.6 s | worst 0.61 s |

Not tested there: real hardware cable pulls, groups of more than two members, IPv6, routes learned by BGP, the Robot regression with this package,
and the side effect named above (more nexthop-group entries when an inactive member is present).
