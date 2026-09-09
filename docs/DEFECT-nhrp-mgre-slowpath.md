# NHRP registration cannot bootstrap over multipoint GRE

Status: **diagnosed, not fixed.** The fault is in the dataplane slow path, not
in `nhrpd`. `ARCHITECTURE-ASSESSMENT.md` concluded the opposite — "blocked in
the daemon itself" — on the strength of nhrpd having crashed once during the
first run. That crash was real but incidental; nhrpd does its job correctly.

## Symptom

A hub-and-spoke DMVPN never forms. On the spoke the NHS stays `(unspec)` and
both caches hold only their own local entry:

```
Iface    FQDN        NBMA        Protocol
tun0     201.1.1.2   201.1.1.2   (unspec)

Iface    Type     Protocol      NBMA        Claimed NBMA   Flags  Identity
tun0     local    172.30.0.2    201.1.1.1   201.1.1.1             -
```

Everything upstream of NHRP is healthy: the tunnels come up in the multipoint
form (`gre remote any local 201.1.1.1`), the NBMA underlay pings, and the
`/32` tunnel-address prerequisite is satisfied.

## What nhrpd is doing

Correctly sending, and never answered:

```
nhrpd: NHS: Register 172.30.0.2 -> 172.30.0.1 (timeout 2)
nhrpd: Send Registration-Request(3) 172.30.0.2 -> 172.30.0.1
nhrpd: PACKET: Send 201.1.1.1 -> 201.1.1.2
       … repeated with timeout 4, 8, 16 — exponential backoff
```

The NBMA pair on the last line is exactly right. `tcpdump -ni tun0` on the
spoke shows the frame leaving, ethertype `0x2001`, carrying
`ac1e 0002 -> ac1e 0001` (172.30.0.2 registering to NHS 172.30.0.1).

## Where it stops

Counters localise it to a single hop. On the spoke, after several minutes of
retries:

| Point | Reading |
|---|---|
| kernel `tun0`, tcpdump | frame present, `Out`, ethertype 0x2001 |
| kernel `tun0`, counters | **TX 0 packets** |
| `.spathintf`, tx | +1 per registration — kernel hands it to the dataplane |
| `.spathintf`, rx | +1 per registration — the dataplane hands it straight back |
| dataplane `tun0` | tx_packets 0, tx_errors 0 |
| dataplane `dp0s3` | the pings and nothing else |

So the packet crosses into the dataplane, is never encapsulated, and is
returned to the kernel. Read `.spathintf` in one direction only and it looks
like a one-way trip into the dataplane, which is the reading that produced the
first, wrong version of the next section.

## Cause

> **This section was wrong in its first version and is rewritten.** It said the
> packet was encapsulated to 0.0.0.0 because `nxt_ip` was NULL. It is not: the
> mark is present and `nxt_ip` is non-NULL. The error came from reading only
> one direction of the `.spathintf` counters. Measuring both directions is what
> corrected it, and the wrong version is worth remembering: it was self
> consistent, matched the code, and was false.

`shadow.c`, handling a packet the kernel sent on a tunnel, takes the peer's
NBMA address from the metadata mark, marks the packet as having come from the
kernel, and hands it to GRE:

```c
if (!(meta.flags & TUN_META_FLAG_MARK))
        dst = NULL;
else {
        dst_addr = meta.mark;
        dst = mgre_nbma_to_tun_addr(ifp, &dst_addr);
}
...
pktmbuf_mdata_set(m, PKT_MDATA_FROM_US);
...
gre_tunnel_fragment_and_send(host_ifp, ifp, dst, m, ntohs(pi.proto));
```

`gre_tunnel_encap()` then looks the peer up by tunnel address, and on a miss
punts to the kernel:

```c
if (sc->scg_multipoint && nxt_ip) {
        rt_info = mgre_rtinfo_lookup(sc, &tun_addr);
        if (rt_info) { /* send */ }
        else          { goto slow_path; }
}
...
slow_path:
        ip_local_deliver(input_ifp, m);
```

For a packet off the forwarding path that punt is correct -- it is how NHRP
resolution starts. For a packet the kernel just handed over it is a dead end:
`ip_local_deliver()` gives it straight back to the sender, and it dies there
having moved no counter on either side.

The `.spathintf` counters show the bounce, and only if both directions are
read. Over 45 seconds carrying four NHRP registrations:

```
.spathintf  tx: 13 -> 17     kernel handed 4 packets to the dataplane
.spathintf  rx: 13 -> 17     the dataplane handed 4 straight back
kernel tun0 rx/tx: 0 -> 0
dataplane tun0 tx_packets 0, tx_errors 0
```

## Why it cannot bootstrap

`ip neigh show dev tun0` is empty on both routers throughout. That is not a
bug: FRR's nhrpd sends its own control packets through an `AF_PACKET` socket
with the NBMA address in the link-layer destination, deliberately bypassing the
neighbour table, because the neighbour entry is the thing NHRP exists to create.

The mGRE peer table that `mgre_rtinfo_lookup()` searches is populated from
exactly those neighbour messages -- `mgre_newneigh()` in `gre.c`, driven by the
NHRP netlink notifications `ip_netlink.c` handles. So the lookup cannot succeed
until the registration it is blocking has succeeded. Registration can never
complete, and no amount of retrying changes that.

## What a fix has to do

Give `gre_tunnel_encap()` a peer for a tunnel address that has no neighbour
entry yet, for the duration of the bootstrap. The link-layer destination nhrpd
already sets is the natural source -- on a GRE device the hardware address *is*
the four-byte NBMA address -- but `spath_receive()` reads the frame as L3 plus
`struct tun_meta`, and the link-layer destination is not among the fields
carried across.

Two candidate directions, neither yet attempted:

1. Carry the link-layer destination across the tun device alongside `mark`, and
   use it when the peer lookup misses. Touches the kernel extension as well as
   the dataplane.
2. Seed the mGRE peer table from the tunnel's NHS configuration, so the NHS has
   an entry before any registration is attempted. Confines the change to the
   dataplane and the component, but duplicates knowledge that belongs to nhrpd.

What has been done, which is not a fix: the dead-end punt is now counted as an
output error on the tunnel instead of happening in silence, and a multipoint
packet with no destination at all is dropped rather than encapsulated to
0.0.0.0. Neither makes DMVPN work; both make its failure visible, which took
several hours and a wrong diagnosis to establish the first time.

## Also found

`nhrpd` is absent from `daemons.danos` — there is no `nhrpd=` line at all, so
it never starts on a shipped image. It was enabled by hand for this
investigation. Adding it is premature while the above stands: it would start a
daemon that cannot complete a registration.

## Reproducing

Topology `TOPO=bgp` (R1 and R2 share 201.1.1.0/24), then on each router add
`nhrpd=yes` to `/etc/frr/daemons` and restart frr.

```
# hub R2
set interfaces dataplane dp0s3 address 201.1.1.2/24
set interfaces tunnel tun0 encapsulation gre-multipoint
set interfaces tunnel tun0 local-ip 201.1.1.2
set interfaces tunnel tun0 address 172.30.0.1/32
vtysh: interface tun0 / ip nhrp network-id 1 / ip nhrp redirect / ip nhrp shortcut

# spoke R1
set interfaces dataplane dp0s3 address 201.1.1.1/24
set interfaces tunnel tun0 encapsulation gre-multipoint
set interfaces tunnel tun0 local-ip 201.1.1.1
set interfaces tunnel tun0 address 172.30.0.2/32
vtysh: interface tun0 / ip nhrp network-id 1 / ip nhrp nhs 172.30.0.1 nbma 201.1.1.2
```

The tunnel address must be a host prefix; with a `/24` nhrpd refuses outright
(`tun0: 172.30.0.2/24 is not a host prefix`). Any YANG written for this needs
that as a `must`.
