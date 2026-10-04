# Project status and next steps (2026-09-27)

What this project is, evidenced by this week's release-lock work and by
`ARCHITECTURE-ASSESSMENT.md`, `DPA-CAPABILITY-AND-BACKENDS.md` and
`FRR-ROUTE-REPAIR-DECISION.md`, and where the evidence points next. This is not a
new investigation; it reads what those three already established and this
week's runs against a released image, and asks what follows.

**Updated 2026-10-03.** The original text below is kept as written on 2026-09-27;
later facts are added as dated updates, in the style of the corrections already in
section 3C. The main change is in the new "What the hardware bench changed"
block after the overall reading, and in the updates to A, B, D and section 5.

## 1. What is actually established

| Dimension | Evidenced | Gap |
|---|---|---|
| Build and release | Test and product images built from one OBS revision have an identical 1524-package set; SBOM, source-revision map, repository fingerprint and a release directory exist for both | All human-triggered, no CI; each image's evidence is a one-off, not continuously re-checked |
| Protocols and forwarding | 81 Robot cases pass on the product image: BGP, MPLS-LDP, IPsec, firewall, REST | One run, QEMU virtio, software data plane; no throughput, scale or fault injection |
| Boot and signing | Secure Boot chain measured with real OVMF; the signing-check defect (comparing a certificate chain, then trusting MOK for grub/kernel) is fixed and verified on the running image | Virtual firmware only; trust rests on an OBS self-signed certificate enrolled as a MOK |
| DPA | Per-object state is observable (state, backend, enumerable classes); a drift state machine exists | No source of truth for "what should be here"; the interface class covers three interface types only |
| Hardware | All four ports of a physical Intel I210 boot and forward, individually (2026-09-27) | RSS/multi-queue, aggregate/simultaneous throughput, offloads, link-flap recovery, IOMMU/VFIO under Secure Boot, and real firmware boot are all still unmeasured |

**Overall reading.** This is a reproducible, traceable software baseline, not a
releasable product. Its strongest asset is method, not code volume: `toolkit/README.md`'s
rule ("a check must come out differently depending on whether the thing is
true") was violated and caught three times in this week's own work — a
carriage return defeating a whole-line match, a cloud-init check run where
cloud-init cannot start, a stopped container read as a boot failure. The
weakest asset is hardware: all four ports of one physical NIC have run individually
(2026-09-27), which moves it further from "unknown" but still not to "close" -- nothing
has run under load or simultaneously.

### What the hardware bench changed (2026-10-01 to 2026-10-03)

Four identical boxes (Celeron J1900, four Intel **I211** ports each) became available, so
"Hardware" is no longer one machine run port by port. What was measured, with the limits that go
with each number (full detail in `DEFECTS.md`, sections dated 2026-10-02 and 2026-10-03):

| Dimension | Now evidenced on hardware | Still open |
|---|---|---|
| Forwarding | One port, one direction, through the data plane: TCP 934 / 941 Mbit/s with 0 retransmits, UDP 950 Mbit/s with 0.007% loss; TCP in both directions at once 935 / 939 Mbit/s | **Small packets top out near 0.22 Mpps** one way (about 15% of 64-byte line rate), loss at the core-to-core ring, 3 forwarding cores, 1 queue per port. Two-way small-packet rate not measured (the test endpoint was the limit). No multi-queue/RSS (an I211 port has at most 2 queues), no IMIX |
| Punt path | Traffic *to* a DANOS box measured separately: TCP 311 / 573 Mbit/s, UDP 458 Mbit/s received of 900 | A benchmark whose far end is a DANOS router measures that router, not the path under test |
| QoS | A 500 Mbit/s shaper holds iperf3 payload to about 475 Mbit/s; the first TCP run after removing it was slow for about 10 s | Only the software path; the hardware (FAL) path was not exercised |
| Upgrade and rollback | `add system image` of a 2608 ISO onto a 5.57 system, reboot into it, roll back by default-boot, delete it: all work; the defect 14 checksum no longer fails | Configuration is per image (rollback drops changes made since the upgrade); only a same-version image was added, so no cross-release configuration migration is shown |
| 2105 to 2608 | `add system image` from 2105 now passes the checksum and fails at mounting the live rootfs (a deliberate compat symlink collides with the 2105 installer). A 2105 configuration loads on 2608 with no warnings and QoS, firewall, NAT, VLAN interfaces came up | **Owner decision 2026-10-02: this upgrade work is stopped.** Secrets cannot be exported from an `admin`-level 2105 account (masked); credential carry-over untested |
| Routing protocols | OSPF (two adjacencies, equal-cost paths) and eBGP between two boxes run | Runtime state was checked only for these two boxes |
| Fault behaviour | **Forwarded traffic fails over in under a second** on a pulled cable (0.8-0.9 s lost, two pulls, data plane tables on both routers moved within about a second). **Router-originated traffic** that depends on the kernel route can be lost for 8 s to at least 68 s with two parallel links, although OSPF and BGP reconverge in under a second; the kernel interface never loses carrier | Whether the kernel lags depends on the configuration: it did in 8 of 8 pulls with one eBGP session plus OSPF backup and in 0 of 3 with an added loopback BGP path (hypothesis: a post-failure equal-cost group that still holds the dead next hop; untested); the earlier "waits for neighbour FAILED" correlation did not hold in the third run and the 53 s bound was exceeded; long-flow throughput under a pull and the exposed router-originated traffic types were not measured; nothing changed, and not covered by decision 4, so open |
| DPA | All ten object classes enumerate, `qos-if` and `qos-vlan` included, verified on hardware (below) | See section 3B |

**Corrections to this document's own premises.** The hardware is **I211**, not I210 as the original table
and section 3D say; both use the `igb` driver, which is probably how the model was recorded, and it is
unknown whether the 2026-09-27 box was one of these four. "Same physical machine" was shown there by a
matching `HW UUID`; the four boxes report the **same** DMI `product_uuid`, so that evidence does not
identify a machine. **The J1900 has no VT-d** (`/sys/kernel/iommu_groups` is empty), so the IOMMU /
Secure Boot gate cannot be exercised on any of these four boxes.

## 2. Structural findings worth carrying forward

1. **Drift is not rare.** `FRR-ROUTE-REPAIR-DECISION.md` section 4a measured it
   under the full 81-case regression, nothing injected: 43.3% of readable
   comparison cycles over 75 minutes carried a disagreement, one key persisting
   about nine minutes. Explicitly a lower bound from one workload, not a
   production rate. "All tests pass" and "state is consistent" are different
   claims.
2. **The state model answers the wrong question.** Per that document's central
   finding, the data plane records *what happened when an object was
   programmed*, not *what the object should be*. Every repair or reconciliation
   idea depends on an answer to the second question that does not exist yet.
3. **The interface class is narrower than it looks, confirmed by this week's own
   run.** Only interface types that define `ifop_l3_enable` — `dpdk-eth`, `gre`,
   `vlan` — are ever listed. A bridge SVI with a live address and a bridged
   member port, and a loopback with an address, were both configured on the
   installed 5.57 product image and neither appears (see `DEFECTS.md`, the
   interface-class sections). Any tool that treats "not in the class" as "not
   drifted" is silently blind to those types — exactly the failure mode the
   project's own verification principle exists to catch.
4. **Signing trust has a clock.** The OBS certificate expires 2028-10-29 (shim
   was measured to still boot past that date); GRUB's SBAT generation
   (`grub,5`) sits at the current floor, and a revocation to generation 6 stops
   currently-signed images under Secure Boot. This is an ongoing cost of the
   release, not a one-time fix.
5. **Infrastructure is a single point.** One 23 GB development host, shared
   with unrelated work, repeatedly near full disk. This week alone produced at
   least four failures that read as product failures and were host issues:
   disk full twice, a tmpfs exhausted by another project, a stopped Docker
   container, and an unrelated process holding 9.7 GB of memory during a boot
   timeout. (2026-10-03: the root filesystem again reached 100% with 861 MB free; about
   13 GB of regenerable QEMU disk images from past acceptance runs were removed, reports kept.)

## 3. Five lines of work, and where the evidence points

### A. Close the release loop (recommended first — cheapest, most repeated pain)

- Turn `accept-disk-install.sh`, `accept-lifecycle.sh`, the 81-case regression,
  `verify-iso.sh` and `mk-release.py` into one release gate with a preflight
  that checks the things that failed sideways this week: is `danos-robot`
  running, are there stray QEMU processes, is there disk and memory headroom.
  A gate that reports "container not running" is worth more than one more
  correct product result obtained the slow way.
- Pin each release directory to the exact ISO hash it was generated from
  (already recorded in `build-inputs.json`; make it load-bearing, not just
  descriptive).
- Close two named gaps: an upgrade across a kernel change (both current images
  share `6.12.107`), and cloud-init on an installed disk (it currently cannot
  run there by design — decide whether to add an installed-disk path for it or
  document it as unsupported, rather than leaving it silently untested).
- **Exit criterion:** one command, on a clean host, from an OBS revision to two
  verified images and their release directories.
- **Update (2026-09-30):** met. `toolkit/release/close-the-loop.sh` runs OBS all-green check, an
  immutable R2 snapshot, a containerized ISO build, QEMU acceptance, a provenance archive and the
  release directory in one command; product and test images built from the same snapshot have an
  identical package manifest (1522 packages in that build; the 1524 in the table above was the
  earlier pair); wired into GitHub Actions with a self-hosted runner, manually triggered. The
  2026-10-01 release image (`i-danos_vyatta_20261001T1242`) carries `vyatta-dataplane` 3.14.44 and
  `vyatta-image-tools` 5.57. Not part of the exit criterion and still open: the two named gaps above.

### B. DPA: a coverage contract before any repair

`FRR-ROUTE-REPAIR-DECISION.md` lays out two repair options (A: a downstream FRR
route-replay patch, PoC exists; B: reconciliation inside DANOS, needs
desired-state semantics that do not exist) and deliberately does not choose.
Given findings 2 and 3 above, the recommendation here is to build **neither**
yet:

- First, a machine-readable coverage manifest per object class: enumerable or
  not, excluded types and why, comparable against zebra or not. The drift tool
  should report "unknown" for anything not covered, never "clean." This is
  cheap and is a precondition for any later repair work, on either option.
- If repair is then justified, start narrow (single IPv4/IPv6 route replay,
  default off), and settle who owns desired state (zebra, or a DANOS-side
  store — which then has two writers to reconcile against each other) before
  writing code.
- **What would change this recommendation:** evidence that some class of drift
  persists under real load and causes a forwarding error, not just a
  diagnostic disagreement.
- **Update (2026-10-02/03), coverage:** `qos-if` and `qos-vlan` previously reported "no walker", which a
  reader cannot tell apart from "no QoS configured"; both now enumerate (`vyatta-dataplane` 3.14.44,
  `e8d90d90`), so all ten classes are walkable and the coverage manifest says so. They report
  *software* scheduler state (one `qos-if` per port, one `qos-vlan` per VLAN subport) and consult the
  hardware object database only on the FAL path. Checked three ways: a unit test (and a mutation of the
  walker that the test caught), and on hardware, where `qos-if:dp0p4s0` and `qos-vlan:dp0p4s0/10`,
  `/20` appeared as `full` on `sw-dataplane`, removing only VLAN 20's policy removed only `/20`, and
  removing the rest left both classes `enumerable: true` with no objects. **Untested:** the hardware
  (FAL) path and the `no_support` mapping. Diagnostic only; no repair code, per the owner's decision.
- **Update (2026-10-03), the trigger condition, partly:** B says repair is only justified by drift that
  causes a forwarding error under real load. The nearest evidence so far is not about DPA: under an
  injected link fault the *kernel* route disagreed with FRR's for 8 s to at least 68 s (and, with an
  admin-down injection, was sometimes missing altogether, 3 of 15 timed trials). It is a fault, not
  load, at the FRR/kernel layer. **The data plane's own table was then observed (transit test,
  2026-10-03) and followed the control plane within about a second on both routers; a ping forwarded
  through both data planes lost 0.8-0.9 s.** So the disagreement did not reach forwarded traffic in that
  test and the condition for B is still not met. A remaining limit: the data plane's route *objects* on
  `sw-dataplane` read `no_support` and carry no next hop, so the object view could not have shown the
  kernel disagreement; the next-hop check had to use `vplsh route lookup`.
  Also unexplained: VLAN sub-interfaces read `no_support` in the interface class while physical ports
  read `not_needed`.

### C. Backend contract (capability + per-object backend) -- built, and extended further

**Correction (2026-09-28): this recommendation described work that was already
done two weeks before this document was written** (`e28f399a`, `c1b36133`,
`71ec9442`, all 2026-09-14) -- capability answerable before programming, a
backend naming itself, per-object backend recording, and operator visibility
through `fal capability show` and `pd show dataplane route full`, all verified
by `whole_dp`'s `dp_test_fal_capability.c` with two real loaded test backends
declaring a deliberately mixed capability set. This document cited
`DPA-CAPABILITY-AND-BACKENDS.md`'s own "What to build next" section without
noticing that section was already stale when this document was written; both
are now corrected. Since then, one further piece has been closed: v4 and v6
routes shared one capability check (`FAL_CAP_IPV4`) because they share one
handler struct and dispatch token, so a v6 route's backend selection and
per-object recording could both be wrong; fixed in `696771b4`
(`FAL_OP_GROUP_IPV6` plus group-parameterized dispatch macros), verified with a
new test checked able to fail before being trusted.

What remains, correctly scoped: of the 187 total dispatch call sites, roughly
186 still pick a capability per *op_type* rather than per object -- mostly
harmless where a call site's objects cannot differ in kind, real for
ports/interfaces/LAG/STP/mirroring/BFD/the switch, which still select the first
loaded backend by deliberate deferral, not oversight. And no two backends have
been loaded together outside two test plugins in `whole_dp` -- a recording-only
second backend on real hardware, as originally proposed here, is still not
done and is the concrete next increment if this line continues.

### D. Real hardware — no longer untouched, still the largest unknown

- **Update (2026-09-27):** two physical runs have happened. A 5.57 product
  image, freshly installed (not upgraded — see the defect 14 checksum finding
  below) on a BayTrail box with a 4-port Intel I210, brought `vyatta-dataplane`,
  `frr` and `configd` up clean; the second run moved a single test cable across
  all four ports in turn and got the identical result on each: gigabit link,
  ping and ssh both ways, non-zero traffic counters. See `DEFECTS.md`, defect
  14's "Confirmed on real hardware" note and the section "Real hardware: 2608
  boots, and its data plane forwards, on a physical I210 NIC". This closes "does
  DPDK bind and forward on this hardware, on every port," not "is it
  production-ready on hardware": no two ports carried traffic at the same time,
  and nothing ran under load.
- Smallest useful next test, unchanged in kind, narrower in scope now that every
  port individually works: real load and multiple ports simultaneously (RSS,
  multi-queue, aggregate throughput), the Secure Boot IOMMU gate (`vplane-uio`
  requires it by design, per `DEFECTS.md` defect 19 — not exercised, since this
  run did not enable Secure Boot), recovery from a link flap, and the boot chain
  on real firmware (not OVMF, and this run did not test Secure Boot on this
  hardware either).
- Doing the rest early, not last, is still the right call: multi-queue,
  sustained throughput and IOMMU/VFIO are exactly where QEMU is least likely to
  reproduce a real failure, and they gate whether "production" is an honest
  word to use.
- **Update (2026-10-01 to 2026-10-03):** four J1900 / I211 boxes, one serial adapter, no switch. What
  ran, and what each result does and does not say, is in the block "What the hardware bench changed"
  above. Of the 2026-09-27 list: *aggregate/simultaneous throughput* is partly done (both directions
  of one port pair at once; four ports simultaneously was not), *link-flap recovery* is done for a
  pulled cable under a light 10-packets-per-second probe and found to be a real weakness, *multi-queue/RSS*
  is not done and an I211 caps at two queues, *offloads* untested. **Not possible on this hardware:**
  the Secure Boot IOMMU gate (no VT-d), so item D's IOMMU/VFIO part needs a different machine, and
  real-firmware Secure Boot was not attempted. Method notes the next person will want (live-image
  plain-host recipe, serial prompt traps, sandbox account) are at the end of the 2026-10-02 sections of
  `DEFECTS.md`.

### E. Feature scope — hold, do not extend

Agreed with `ARCHITECTURE-ASSESSMENT.md`'s position: adding protocol count
returns less than making what exists explainable and reproducible. Its own
"daemon ships, CLI missing" pattern (RIP recorded as covered when it was not;
`pathd` has label stacks but not segment routing; `nhrpd`'s data plane is ready
and the daemon is not) is a warning about claiming coverage before a check that
can fail exists for it. If one direction must be chosen for productisation,
EVPN-VXLAN is the most complete on paper and is the reasonable flagship; VPLS,
SR-TE and NHRP stay held. Replacing the data plane with VPP, or adding
Sysrepo/Netopeer2 as a second configuration core, are both addressed directly
in `ARCHITECTURE-ASSESSMENT.md` (228k verified lines, an existing DPA, a
duplicated configuration core) and are not reopened here; VPP belongs only as a
second backend to compare once C exists.

## 4. Suggested order

```
A (release gate)  ─┬─▶ B (coverage manifest)  ─▶  repair, only if B's evidence justifies it
                    │
                    └─▶ D (minimal hardware experiment, in parallel — needs a machine)
                             │
                             ▼
                    C (recording-only second backend)
```

Each step is defined by an exit criterion, not a duration. Any timeline in
another document (this project's own or an external assessment) is that
document's judgment, not verified here.

**Update (2026-10-03):** A is closed. B's coverage step is closed for the object classes that exist. D
is no longer blocked on a machine, but is now blocked, for the IOMMU part, on a machine *with VT-d*. The
fault-behaviour finding (router-originated traffic 8 s to at least 68 s on a pulled cable, forwarded traffic under 1 s) is new work that was not in this order; what to do
about it is open (section 5).

## 5. Decisions this needs from the project owner

1. **Intended use** — lab/research baseline, CPE, or a commercial release?
   Determines how far the hardware and Secure Boot trust work has to go.
2. **Hardware** — one machine has run all four ports individually; is it (or another) available for the rest of D (simultaneous load, Secure Boot on real firmware)?
3. **Secure Boot trust** — is a long-term OBS self-signed certificate enrolled
   as a MOK (operator enrollment required) acceptable, or does this need
   Debian-signed boot components instead (which would give up the custom
   kernel)?
4. **Repair posture** — is "diagnose first, repair off by default" acceptable
   as the working rule until B's coverage manifest exists?

**Answers recorded 2026-10-01 / 2026-10-02:**

1. Intended use: **commercial release.**
2. Hardware: none at first; **superseded 2026-10-02** by four J1900 / I211 boxes (no VT-d).
3. Secure Boot trust: **accepted**, OBS self-signed certificate plus MOK, with the expiry
   (2028-10-29) and SBAT-revocation risk managed as a running cost.
4. Repair posture: **accepted**, diagnose first, repair off by default; no repair or reconciliation
   code is written until a class of drift is shown to cause a forwarding error under real load.
5. (new) **2105 to 2608 upgrade work: stopped** (2026-10-02). The supported route off 2105 is a fresh
   install plus configuration carry-over, with the limits in `DEFECTS.md`.

**Open, needing the owner:**

6. The kernel-route hole (8 s to at least 68 s) when a cable is pulled between two routers with parallel links. Forwarded traffic is not affected on the evidence (under 1 s); router-originated traffic is. Options a
   person could evaluate, none applied or tested: BFD between the routers, shorter neighbour timers,
   propagating link loss to the kernel carrier, or avoiding equal-cost groups that contain a path
   through a port whose link is down. Nothing has been changed. Decision 4 covers route repair and
   reconciliation code, not this (a kernel-interface or timer change), so it is open for the owner to decide.
7. Hardware with VT-d for the IOMMU / Secure Boot part of D, or a decision to leave that part unproven.

## Sources

`ARCHITECTURE-ASSESSMENT.md`, `DPA-CAPABILITY-AND-BACKENDS.md`,
`FRR-ROUTE-REPAIR-DECISION.md`, `DEFECTS.md` (interface-class sections, defects
19, 21, 22, 23), this week's release directories under
`/home/aikon/danos/releases/i-danos_2608_20260926*` and their
`verification-summary.json`. Updates: the sections of `DEFECTS.md` headed "Real hardware" and dated
2026-10-02 and 2026-10-03, `toolkit/vm/dpa-coverage-manifest.py`, and
`/home/aikon/danos/releases/i-danos_vyatta_20261001T1242-amd64.hybrid`.
