# L2VPN: EVPN-VXLAN rather than VPLS

Status: **a MAC learned by EVPN forwards, and it is configurable, both
measured on the built image.** The roadmap carried VPLS/VPWS as the remaining
L2VPN item. Four of the five pieces EVPN-VXLAN needs were already here; the
fifth has since been written, along with four dataplane fixes without which
none of it forwarded and a configuration model without which none of it
survived a reboot. VPLS has none of the five and is not worth starting.

An earlier revision of this document said "done, end to end" and claimed
forwarding had been proven. It had not been -- the test could not have shown
what it claimed, and the feature did not in fact work. See
[The test that proved nothing](#the-test-that-proved-nothing) below. The
correction is kept rather than edited away because the way the wrong answer
arrived is the reusable part.

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
| Local MAC: dataplane → kernel → BGP | **no such path** — written since, see below |

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

## The gap, and how it was closed

Locally learned MACs never left the dataplane:

```c
/* bridge_rtupdate(), bridge.c */
fal_br_new_neigh(ifp->if_index, vlan, dst, 1, &attr);
```

Learning updated the dataplane's own `bridge_rtnode` table and reported to FAL
-- the hardware abstraction -- and to nothing else. zebra reads the *kernel*
bridge FDB to decide which local MACs to advertise as EVPN type-2 routes, so it
saw none. `show evpn vni` reported `# MACs 0` while the dataplane's own table
held several dynamic entries on the same interface.

The bridge now reports them. Three decisions in that are worth keeping:

**From the ageing timer, not from the learning path.** `bridge_rtupdate()` runs
per packet per core and has no business making a syscall. The timer already
walks the whole table every two seconds on the master lcore, and two seconds is
immaterial to EVPN, which takes longer than that to converge.

**Only for a bridge with a VXLAN member.** That is what puts zebra in the
picture. Every other bridge's kernel FDB is read by nothing, and filling it
would be churn for no reader.

**Not MACs learned on the VXLAN interface.** Those arrived from the far side
and belong to somebody else; reporting one as local would have zebra advertise
it back as a route owned by this VTEP. The first version did exactly that --
the kernel FDB filled with four entries and every one of them was `dev tun0`.
The mechanism worked and was pointed the wrong way, which is a failure that no
test of "did anything reach the kernel" can see.

## Measured end to end

One MAC, every hop, on `TOPO=ipsec` with R2 bridging a local port toward R3:

| Hop | Reading |
|---|---|
| R2 dataplane learns it locally | `"mac":"52:54:0:3:8:1","port":"dp0s8"` |
| R2 kernel FDB | `52:54:00:03:08:01 dev dp0s8 master br0` |
| R2 zebra | `# MACs 1`, `52:54:00:03:08:01 local dp0s8` |
| BGP type-2 | `[2]:[0]:[48]:[52:54:00:03:08:01]` and `...:[32]:[10.61.61.3]`, RT `65000:100` |
| R1 zebra | `52:54:00:03:08:01 remote 10.60.60.2` |
| R1 kernel FDB | `52:54:00:03:08:01 dst 10.60.60.2 self extern_learn` |
| R1 dataplane | present |

`# MACs 1` rather than more is the point: only the locally learned MAC is
advertised, which is the third decision above being visibly right. The two
type-2 routes -- MAC-only and MAC+IP -- mean the information ARP suppression
needs is there as well.

The five Robot suites pass 74 of 74 on the same image, which matters here
because the change adds a syscall to a bridge timer.

## Why this is cheaper than VPLS

| | VPLS/VPWS | EVPN-VXLAN |
|---|---|---|
| Forwarding plane | from nothing | measured working |
| Remote MAC programming | from nothing | measured working |
| Control plane | ldpd pseudowire signalling, from nothing | bgpd, shipped, session up |
| Control plane to interface model | from nothing | zebra finds the VNI on its own |
| Remaining work | pseudowire encapsulation, signalling, split horizon, per-PW learning | YANG/CLI, and confirming the forwarding fix on a built image |

EVPN is also what VPLS was replaced by. Choosing it is not only cheaper here,
it is the direction the rest of the industry already went.

## The test that proved nothing

The hop table above stops at "R1 dataplane: present". The obvious next question
is whether R1 *forwards* by it, and the first attempt at answering it went
wrong in a way worth recording.

Reachability alone cannot separate "forwards because of the EVPN entry" from
"forwards because flooding reached the same place" — with one remote VTEP both
go to the same address. So the flood path was made a dead end: R1's tunnel
`remote-ip` was set to 10.60.60.99, which nothing answers, while the EVPN entry
named the real VTEP 10.60.60.2. Measured in both states, the ping failed before
EVPN and succeeded after, and that was read as proof.

It is not proof, because R1 and R2 are bridged. Blocking the flood path *out of*
R1 does nothing about learning *into* R1: every frame R2 floods toward R1
teaches R1 the source MAC together with the source VTEP. Dumping the table
instead of inferring from reachability showed R3's MAC already sitting in R1
before EVPN was configured at all:

```
"mac": "52:54:0:3:8:1", "IPAddr": "10.60.60.2", "type": "dynamic"
```

`dynamic` is the data path's own learning. The entry that carried the traffic
was never the EVPN one. (`IPAddr` is the old field name; the probe ran on the
image that was installed, before any of the fixes below.)

The same dump showed something worse. Once EVPN programmed that MAC, the entry
lost its VTEP — the field printed the MAC string instead of an address, which
is what this dump does when neither address flag is set. `vxlan_output()` tests
those same flags:

```c
if (vxlrt->vxlrt_flags & IFBAF_ADDR_V4) { ... }
else if (vxlrt->vxlrt_flags & IFBAF_ADDR_V6) { ... }
else
        goto drop;
```

`vxlan_newneigh()` set neither, so **no MAC that EVPN learns was forwardable**,
and a netlink update about a MAC the data path already knew *cleared* the flag
off a working entry and turned it into a black hole until the data path learned
it again. Its update branch also never refreshed `vxlrt_dst`, which is how a
MAC move is signalled, so a moved host would have gone on being encapsulated to
the VTEP it had left.

Two things made this survive as long as it did:

- **The symptom looked cosmetic.** A MAC in an address field reads as a
  formatting bug. It was the visible end of a forwarding defect, and it was
  filed as a display nuisance for two rounds.
- **The test was built from the product's own reachability.** Every signal it
  used was one the defect could satisfy by accident. Asking the table what it
  held took one command and answered immediately.

`toolkit/vm/probe-vxlan-mac-origin.sh` is that probe.

## The distinction the table could not make

Rewriting the test needed a way to say which entry was which, and the first
attempt at that was wrong too: `type: permanent` for netlink, `type: dynamic`
for the data path. FRR's remote MACs come in with an NUD state that maps to
`IFBAF_DYNAMIC`, exactly like a MAC off the wire, so that discriminator would
have reported INCONCLUSIVE on every run. The probe log had said so plainly —
the EVPN entry read `"type": "dynamic"` — and it was read past.

What separates them is `NTF_EXT_LEARNED`, which FRR sets on every remote MAC
and which nothing in the dataplane kept. Recording it fixed two further
defects that had the same root:

- **`vxlan_rtexpired()` aged control-plane entries.** It ages anything
  `IFBAF_DYNAMIC` after thirty minutes of disuse, which included every MAC EVPN
  had learned. FRR's own state would not have changed, so nothing would have
  reprogrammed them: a remote host that goes quiet for half an hour simply
  stops being reachable, and comes back the moment it speaks — the shape of
  fault that gets filed as "intermittent" and never reproduced.
- **`vxlan_rtupdate()` let the data path overwrite them.** A frame from any
  VTEP could repoint an entry BGP had placed. EVPN settles a MAC appearing in
  two places with type-2 sequence numbers and duplicate-address detection, and
  both depend on the dataplane not quietly picking a winner of its own.

The dump now reports `origin`: `control-plane` for `NTF_EXT_LEARNED`,
`data-path` for what the wire taught us, `configured` for a static or permanent
entry, which is netlink but an operator rather than a protocol. That was the
first question worth asking of an EVPN fabric and the system could not answer
it.

The order matters more than the fixes. The earlier test was not merely wrong,
it was unfixable: its premise was that flooding and EVPN reach different places,
and the real distinction was never about reachability. Nothing sound could be
tested until the table could state it. `verify-evpn-forwarding.sh` is built on
`origin`, and where it cannot conclude it prints the `NEWNEIGH` log line
carrying `ndm_flags`, so "the flag never arrived" and "the flag was not kept"
are not confusable.

Trade accepted: entries a control plane owns now never age out of the
dataplane. If FRR dies without withdrawing them they stay until it restarts and
resyncs. That is the usual bargain for control-plane ownership, and the
alternative — ageing out routes a protocol still believes in — is the defect
that was just fixed.

## The instrument, and the one defect that really was separate

**`vxlan macs show` printed the wrong fields — and it was not cosmetic.**
One buffer was shared between the MAC and the VTEP, so an entry with no address
flag printed the leftover MAC in the VTEP field; that buffer was also
`INET_ADDRSTRLEN`, two bytes short of what `ether_ntoa_r()` can write and thirty
short of an IPv6 address. The dump now uses separate, correctly sized buffers,
names the field `remote_ip` rather than `IPAddr` (it is the VTEP, never the host
address an EVPN type-2 route also carries), says outright whether the entry can
forward, and prints `permanent` where it used to print `local` — which was read
as a claim about where the MAC lives, the opposite of the truth for a remote
VTEP. MACs print zero-padded via `ether_ntoa_canon()`, because `ether_ntoa_r()`
drops leading zeros and nothing else in the stack does: comparing this output
against the kernel or FRR meant comparing `52:54:0:3:8:1` against
`52:54:00:03:08:01`, which silently matches nothing. That mismatch is what let
the first forwarding test report "not in the dataplane" and be dismissed as a
grep problem.

**eBGP needs a policy or the session carries nothing.** With AS 65001 and
65002, `show bgp l2vpn evpn summary` reports `(Policy)` in place of a prefix
count and no routes are exchanged. FRR has defaulted to
`bgp ebgp-requires-policy` since 7.4. Use iBGP for a lab, or disable it
explicitly.

## Reproducing

`toolkit/vm/verify-vxlan-evpn-viability.sh`, `verify-evpn-last-hop.sh`,
`verify-evpn-e2e.sh` and `verify-evpn-forwarding.sh`, on `TOPO=ipsec`;
`probe-vxlan-mac-origin.sh` is read-only and answers "what is actually in the
table" without asserting anything. `verify-evpn-e2e.sh` walks all five hops; it
needs three routers, because R2 has to bridge a local port with something
behind it. An earlier version bridged only the tunnel at both ends, which left
nothing local to advertise -- "0 MACs" was then the correct answer to a
question worth nothing.

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

## The CLI

Everything above was typed into `vtysh`, which meant the feature survived no
commit, appeared in no `show configuration`, and was lost on reboot. It is
modelled now, shaped on the `vpnv4-unicast` containers this repository already
had:

```
set protocols bgp 65000 address-family l2vpn-evpn advertise-all-vni
set protocols bgp 65000 address-family l2vpn-evpn vni 100 rd 65000:100
set protocols bgp 65000 address-family l2vpn-evpn vni 100 route-target import 65000:777
set protocols bgp 65000 neighbor 10.60.60.2 address-family l2vpn-evpn
```

The global container decides which VNIs there are to advertise; the neighbour
one activates the session for the family. Either alone exchanges no MACs,
which is the mistake this address family invites and which both descriptions
state.

Operationally there are two views, and they answer different questions:

| Command | Answers |
|---|---|
| `show protocols bgp l2vpn evpn …` | what BGP holds |
| `show protocols evpn …` | what zebra learned and programmed |

A MAC in the first and missing from the second is the shape of fault this
document is mostly about, and until now the CLI could show neither.

`toolkit/vm/verify-evpn-cli.sh` covers it: 22 checks, all passing on
`i-danos_2608_20260911T2143`, including a MAC learned through a session that
was never configured by hand. The five suites pass 74 of 74 on the same image.

Its first run reported 11 failures and every one was the test. Nine were the
way it invoked operational commands -- `vcli` is the configuration client and
answers `show ...` with silence and exit 0. The tell was that `show version`
came back empty through the same path: a real fault in nine commands does not
also break an unrelated tenth, and checking that the instrument reads anything
at all costs one command. Two were the route target value: FRR derives a VNI's
route target from the AS and the VNI, so `65000:100` on VNI 100 in AS 65000 is
the derived value, configuring it is a no-op, and the check demanded a line
the system was entitled not to produce.

That is the same shape as the `OutDiscards` check described above, which
corroborated a verdict with a reading that had failed. Three times in one
week, an assertion rested on a signal nobody had confirmed the system emits.

## What this does not say

That EVPN-VXLAN is finished as a product feature. The mechanism carries a MAC
end to end, the dataplane forwards by it, and it is configurable. Not covered:
EVPN under a routing instance, which is the symmetric IRB case and a larger
piece of work than any of this.

What was measured, on `i-danos_2608_20260911T0944` with the running
`/usr/sbin/dataplane` checksummed against the binary the verification ran on:

| Reading | Result |
|---|---|
| Only entry present when traffic went out | `control-plane dynamic 10.60.60.2 True` |
| R1 -> R3, flood path pointed at 10.60.60.99 | **3 of 3** |
| `OutDiscards` across the ping | `0 -> 0` |
| Entry origin afterwards | still `control-plane` |
| Five Robot suites | **74 of 74** |

The last row matters because the change adds a branch to the VXLAN ageing
timer and takes one away from the learning path. The checksum row matters
because `mk-obs-repo.sh` reported the public mirror still serving the previous
dataplane build and fell back to the OBS API for it -- without that fallback
the image would have carried the old binary and every suite would still have
passed.

What is outstanding:

- **IPv6 VTEPs do not arrive over netlink at all.** `vxlan_neigh_change()`
  rejects any `NDA_DST` that is not four bytes, so `IFBAF_ADDR_V6` can only
  ever be set by data-path learning. EVPN over an IPv6 underlay is therefore
  not supported, and nothing currently says so to the operator.
- **Nothing tests a MAC move.** The update path now refreshes the VTEP, which
  is the behaviour a move depends on, and no test exercises it.
- **Nothing tests the ageing fix.** It takes thirty minutes of silence to
  trigger, so it needs either patience or a build with the interval shortened;
  the fix is a two-line guard and the failure it prevents is intermittent,
  which is the combination least likely to be noticed if it regresses.
