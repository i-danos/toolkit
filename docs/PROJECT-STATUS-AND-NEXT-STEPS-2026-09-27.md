# Project status and next steps (2026-09-27)

What this project is, evidenced by this week's release-lock work and by
`ARCHITECTURE-ASSESSMENT.md`, `DPA-CAPABILITY-AND-BACKENDS.md` and
`FRR-ROUTE-REPAIR-DECISION.md`, and where the evidence points next. This is not a
new investigation; it reads what those three already established and this
week's runs against a released image, and asks what follows.

## 1. What is actually established

| Dimension | Evidenced | Gap |
|---|---|---|
| Build and release | Test and product images built from one OBS revision have an identical 1524-package set; SBOM, source-revision map, repository fingerprint and a release directory exist for both | All human-triggered, no CI; each image's evidence is a one-off, not continuously re-checked |
| Protocols and forwarding | 81 Robot cases pass on the product image: BGP, MPLS-LDP, IPsec, firewall, REST | One run, QEMU virtio, software data plane; no throughput, scale or fault injection |
| Boot and signing | Secure Boot chain measured with real OVMF; the signing-check defect (comparing a certificate chain, then trusting MOK for grub/kernel) is fixed and verified on the running image | Virtual firmware only; trust rests on an OBS self-signed certificate enrolled as a MOK |
| DPA | Per-object state is observable (state, backend, enumerable classes); a drift state machine exists | No source of truth for "what should be here"; the interface class covers three interface types only |
| Hardware | One port of a physical Intel I210 boots and forwards (2026-09-27) | The other three ports, RSS/multi-queue, throughput/scale, offloads, link-flap recovery, IOMMU/VFIO under Secure Boot, and real firmware boot are all still unmeasured |

**Overall reading.** This is a reproducible, traceable software baseline, not a
releasable product. Its strongest asset is method, not code volume: `toolkit/README.md`'s
rule ("a check must come out differently depending on whether the thing is
true") was violated and caught three times in this week's own work — a
carriage return defeating a whole-line match, a cloud-init check run where
cloud-init cannot start, a stopped container read as a boot failure. The
weakest asset is hardware: one port of one physical NIC has run (2026-09-27), which
moves it from "unknown" to "barely started," not to "close."

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
   timeout.

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

### C. Backend contract (capability + per-object backend), buildable without hardware

`DPA-CAPABILITY-AND-BACKENDS.md`'s "What to build next" (capability answerable
before programming, backend identity, per-object backend bits, operator
visibility) is agreed with here: it is identical work regardless of which
software forwarder ends up primary, which is the reason to do it before that
question is settled. `fal.c` already has the plugin mechanism (205 entry
points, a reference backend used 59), so this extends rather than replaces it.
The risk is designing an abstraction against a single real consumer; mitigate
by building a recording-only second backend to exercise load, capability
partial-match, async errors and software fallback without needing hardware.

### D. Real hardware — no longer untouched, still the largest unknown

- **Update (2026-09-27):** a first physical run has happened. A 5.57 product
  image, freshly installed (not upgraded — see the defect 14 checksum finding
  below) on a BayTrail box with a 4-port Intel I210, brought `vyatta-dataplane`,
  `frr` and `configd` up clean, forwarded real ping and ssh traffic on one port
  at gigabit, and its own interface counters showed the traffic moving. See
  `DEFECTS.md`, defect 14's "Confirmed on real hardware" note and the section
  "Real hardware: 2608 boots, and its data plane forwards, on a physical I210
  NIC". This closes "can it run at all," not "is it production-ready on
  hardware."
- Smallest useful next test, unchanged from before this run: DPDK binding on
  the remaining three ports and under real load, the Secure Boot IOMMU gate
  (`vplane-uio` requires it by design, per `DEFECTS.md` defect 19 — not
  exercised, since this run did not enable Secure Boot), recovery from a link
  flap, and the boot chain on real firmware (not OVMF, and this run did not
  test Secure Boot on this hardware either).
- Doing the rest early, not last, is still the right call: multi-queue,
  sustained throughput and IOMMU/VFIO are exactly where QEMU is least likely to
  reproduce a real failure, and they gate whether "production" is an honest
  word to use.

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

## 5. Decisions this needs from the project owner

1. **Intended use** — lab/research baseline, CPE, or a commercial release?
   Determines how far the hardware and Secure Boot trust work has to go.
2. **Hardware** — one machine has run one port; is it (or another) available for the rest of D (other ports, load, Secure Boot on real firmware)?
3. **Secure Boot trust** — is a long-term OBS self-signed certificate enrolled
   as a MOK (operator enrollment required) acceptable, or does this need
   Debian-signed boot components instead (which would give up the custom
   kernel)?
4. **Repair posture** — is "diagnose first, repair off by default" acceptable
   as the working rule until B's coverage manifest exists?

## Sources

`ARCHITECTURE-ASSESSMENT.md`, `DPA-CAPABILITY-AND-BACKENDS.md`,
`FRR-ROUTE-REPAIR-DECISION.md`, `DEFECTS.md` (interface-class sections, defects
19, 21, 22, 23), this week's release directories under
`/home/aikon/danos/releases/i-danos_2608_20260926*` and their
`verification-summary.json`.
