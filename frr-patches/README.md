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
