# What the upstream documentation says, and where this work departs from it

The DANOS wiki documents the project up to 2105, which is the baseline this
port started from. Two things in it bear on work done since, and one of them
is a departure that was made without noticing.

https://danosproject.atlassian.net/wiki/spaces/DAN/overview

## EVPN is not in it

The Configuration Guide covers Tunnelling -- GRE including L2 bridging, IPIP,
L2TPv3, and VXLAN/VTEP -- along with Bridging and VRFlite. There is no EVPN
page and no L2VPN page. The High Level Design Documents section lists one
document, about hardware MPLS on Broadcom Qumran-AX, and nothing about EVPN,
VXLAN or the forwarding model.

So there is no prior design to conform to, and nothing was broken by not
conforming to it. It also explains a wrong turn recorded in
`L2VPN-EVPN-OVER-VPLS.md`: VXLAN appears there as a tunnel type beside GRE and
IPIP, not as a fabric capability, which is consistent with a keyword sweep for
`pseudowire`, `vpls` and `l2vpn` concluding that L2VPN had to be built from
nothing while `vxlan` -- 16 files and 2167 lines -- went unswept.

The model added since is shaped as an extension of what is documented rather
than as a second dialect:

```
set interfaces tunnel tun5 encapsulation vxlan     documented in 2105
set routing routing-instance RED interface br5     documented in 2105
set routing routing-instance RED vni 5000          new
set protocols bgp 65000 address-family l2vpn-evpn  new, augmenting the BGP model
```

`routing routing-instance <name> vni` is the first node here that ties a
tunnel to a routing instance. In the 2105 documentation those are two
unrelated chapters.

## VCI components, and what was used instead

The Architectural Overview is explicit about how a feature should be added:

> VCI Components are a bridge between the YANG modeled data and the native
> service implementing some required functionality.

and about the alternative:

> configuration action scripts ... are considered legacy and are currently
> being replaced by VCI components

Private VLAN and ARP suppression are both configuration action scripts. The
reasoning written into them at the time was about process lifetime -- neither
has a daemon to manage, so neither looked like 802.1X, which exists to run
hostapd. The documentation's reasoning is different: VCI is how a feature
reaches the northbound interfaces, and action scripts are on the way out
regardless of whether they manage a process.

In practice the difference is narrow. The action scripts use the `vplaned`
library, which is the Vplaned API the architecture names; CLI, REST and
NETCONF work from the YANG, which is the same either way, and the REST suite
passes 21 of 21 over both features. What differs is the route the
configuration takes to the dataplane, and which of the two the project intends
to maintain.

**Decided: they stay as action scripts.** Converting them is a resident
component for a stateless switch, plus its packaging, for a difference that
does not reach the operator -- and the local precedent, `vyatta-mac-limit` and
Private VLAN, is what the next person reading this code will find first.

The decision is worth having in writing because the reasoning originally
written into those scripts was not the reasoning that matters. They argue
about process lifetime: neither feature has a daemon, so neither looked like
802.1X, which exists to run hostapd. That is true and it is not the question
the architecture asks. VCI is about how configuration reaches the northbound
interfaces, and an action script is legacy there whether or not a process is
involved. The scripts were right by a coincidence, and a coincidence is not a
precedent -- a future feature that does need a component should not cite them.

If the project later converts the legacy scripts as a body of work, these two
belong in it.
