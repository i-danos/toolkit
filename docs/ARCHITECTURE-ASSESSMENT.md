# Assessment: rebuilding DANOS from open components

A proposal was put forward to drop vendor ASIC SDKs entirely and realise the
original 2018 DANOS architecture from open-source parts — FRR for the control
plane, VPP / OVS-DPDK / P4-DPDK for the data plane, Sysrepo and Netopeer2 for
management, and a new Data Plane Abstraction (DPA) tying them together, with the
explicit advice not to fork DANOS but to rebuild around mature open components.

This records the assessment of that proposal against what 2608 actually is.

## The finding

As a greenfield design it is sound. As the next step for **this** project it
rests on a premise that does not hold: it treats DANOS as a legacy codebase to
be rebuilt around, when what exists here is a working, verified system whose
verification was completed the same week.

## Three direct conflicts

### The DPA already exists

The proposal identifies the data plane abstraction as the one place original
code is genuinely needed. That layer is present and plugin-based:

| | |
|---|---|
| `src/fal.c` | 4,042 lines |
| `include/fal_plugin.h` | 6,602 lines, 205 entry points |
| Loading | `platform_cfg.fal_plugin` → `dlopen`, at `fal.c:739` |
| Reference implementation | `libfal-opennsl` exported 59 symbols |

The 59 against 205 is the useful number: a working backend never had to
implement the whole surface.

### Replacing the data plane discards 228k lines that are verified

`vyatta-dataplane` is 338 C files, 228,524 lines, already built on DPDK, and it
carries `npf` (firewall and NAT), `qos`, `mpls`, `crypto`, `ip_mcast`, `bridge`,
`vlan`, `lag`, `portmonitor` and `sfp`. The whole CLI, YANG, VCI and configd
stack sits on it.

Swapping in VPP is not changing a backend. It means rewriting the firewall, QoS,
crypto and multicast paths together with their configuration models. The
multicast work recorded in `MULTICAST.md` — 5000 of 5000 forwarded,
`fast/dataplane`, `wrong_if 0` — is a reading from this data plane.

### Sysrepo and Netopeer2 duplicate configd and the VCI

The management plane the proposal describes is what `configd` plus the VCI
component bus already do: YANG model, component ownership, generated
configuration, reload. That is the machinery the PIM CLI was built through.

## Availability of the proposed components

Measured against Debian 13, which is what this project builds on:

| Component | Debian 13 |
|---|---|
| `dpdk`, `libdpdk-dev` | 24.11.4 — already in use |
| `openvswitch-switch-dpdk` | 3.5.0 |
| `libyang3` | 3.12.2 |
| `vpp` | absent |
| `sysrepo` | absent |
| `netopeer2` | absent |
| `p4c` | absent |

Two of the three proposed data-plane pillars, and the entire proposed management
plane, would have to be built and maintained outside the distribution. That runs
against the rule that made this upgrade tractable at all — retire the fork where
Debian ships an equivalent — and re-acquires exactly the self-maintained
dependency burden that 2110a→2608 spent its effort shedding.

## What the proposal gets right and is worth keeping

- **The distinction between SAI as an open API and SAI implementations as vendor
  code.** This matches what was found independently here and is the crux of the
  whole question.
- **A capability model rather than a lowest-common-denominator abstraction.**
  This is the real lesson of SAI and belongs in any FAL evolution: a backend
  should declare what it supports rather than every backend being reduced to the
  intersection.
- **BMv2 is not a production data plane.** Correct, and worth stating plainly.
- **Three levels of "open source"** — open NOS, open software data plane, open
  hardware — is a more honest framing than a flat "100% open source" claim,
  given firmware, microcode and BIOS.
- **The strategic reframing**: liberate the NOS from the SDK rather than try to
  replace ASICs. This is right, and it is what 2608 already did.

## The path that fits what exists

Not a rebuild — an open backend behind the abstraction that is already there:

```
vyatta-dataplane   228k lines, verified
       |
      FAL          205 entry points, already present
       |
  +----+----+
  |         |
 new:      current:
 SAI       no backend
 backend   (pure software forwarding)
  |
libsaivs, or a vendor SAI .so
```

The work concentrates in one place: mapping the ~59 FAL entry points a real
backend needs onto SAI calls. That obtains the property the proposal is after —
no vendor SDK — without discarding anything that works.

A minimal spike answers whether the path opens at all, and fails informatively
at whichever step breaks:

1. Build the OCP SAI headers and SONiC's `libsaivs` virtual switch standalone,
   and see whether they compile on Debian 13 with GCC 14.
2. Write a FAL plugin implementing only the L2 port entry points, calling SAI,
   and check it compiles and can be `dlopen`ed.
3. Start the data plane with `fal_plugin` pointing at it and see whether
   initialisation completes.

Note what this would and would not prove. Backed by `libsaivs` it demonstrates
the abstraction working against a **software** backend. Real hardware still
needs a vendor SAI library — but that shrinks the closed surface from an entire
SDK to a single `.so`, which is what SONiC deployments already live with.

## Scoring, as a next step for this project

| | |
|---|---|
| Architecture as a greenfield design | 8/10 |
| Fit with the existing codebase | 2/10 — discards data plane and management plane |
| Dependency availability | 4/10 — two of three pillars absent from Debian |
| Achieves "no vendor SDK" | 9/10 — but 2608 already achieves it |
| Cost to land | 3/10 — equivalent to a rewrite |

## In one line

What the proposal sets out to achieve has already been achieved here: 2608
carries no vendor closed source, its protocol stack is upstream FRR 10.3 and its
data plane is DPDK 24.11. What is missing is an open backend for the hardware
abstraction, and that is a plugin behind FAL, not a new building.

## Closing the gap against OcNOS: what "borrowing" actually buys

Three items from the OcNOS feature comparison were done by adding a CLI over
capability that was already present: multicast, BFD, and BGP L3VPN. Each is
recorded with its forwarding evidence in `MULTICAST.md` and the commit history.

The remaining three are not that shape, and the reason matters when someone
proposes borrowing from VyOS or SONiC.

### The dataplane check comes first

`vyatta-dataplane` is 228k lines and does its own L2 and L3 forwarding. That
single fact decides what is borrowable:

| Feature | Dataplane keyword hits | Verdict |
|---|---|---|
| VPLS / VPWS | `pseudowire`, `vpls`, `l2vpn`, `pw-id` — **0** | New dataplane work |
| 802.1x | `dot1x`, `eapol`, `authenticator` — **0** | See below |
| Private VLAN | `pvlan`, `isolated`, `community`, `secondary-vlan` — **0** | New dataplane work |

The 24 hits for `promiscuous` are NIC promiscuous mode in `if.c`, unrelated to
the private-VLAN port role of the same name.

### Why VyOS and SONiC transfer differently

**VyOS forwards in the kernel.** Its 802.1x is hostapd plus kernel
configuration; its port isolation is the Linux bridge's `BR_ISOLATED` flag.
The behaviour is a good reference and the code does not transfer, because our
packets never reach the kernel bridge.

**SONiC forwards in an ASIC.** Its L2 features are largely SAI calls, and we
have no SAI backend. The architecture is worth reading; the forwarding code is
not ours to reuse.

So for anything that is fundamentally forwarding logic, neither project
shortens the work.

### 802.1x is the exception, and it was measured

The authentication half is not forwarding logic, and it is already packaged.
`hostapd`, `wpasupplicant` and `freeradius` are all in Debian 13.

Verified on a router rather than argued: hostapd in wired-driver mode with its
built-in RADIUS server, wpa_supplicant as supplicant, over a kernel veth pair,
completes EAP-MD5:

```
hostapd     CTRL-EVENT-EAP-SUCCESS
            STA 2a:c0:da:59:44:a9 IEEE 802.1X: authenticated
supplicant  EAP authentication completed successfully
            Connection to 01:80:c2:00:00:03 completed
```

`01:80:c2:00:00:03` is the EAPOL group address, so that is a real frame
exchange. Only one dependency was missing from the image, `libpcsclite1`.

Then the same hostapd on a DPDK interface, which is where it stops:

```
dp0s9: interface state UNINITIALIZED->ENABLED
dp0s9: AP-ENABLED
recv: Network is down
```

It starts and enables, and receives nothing: EAPOL frames are consumed by the
fast path and never reach the shadow interface.

That turns an estimate into a scope:

| Part | Work |
|---|---|
| EAP state machine, RADIUS, session handling | none — hostapd |
| Punt EAPOL (`ETH_P_PAE`, 0x888e) | `shadow_receive.c`, which already punts slow-protocol frames |
| Honour port authorisation in the fast path | L2 forwarding path |
| CLI: YANG, mappings, hostapd config generation | ordinary |

An order of magnitude less than implementing 802.1x, which is the point of
running the viability check before writing any of it.

Private VLAN has no equivalent shortcut: primary/secondary VLAN mapping and the
three port roles are forwarding logic end to end.

`toolkit/vm/verify-dot1x-viability.sh` reproduces both halves of this.
