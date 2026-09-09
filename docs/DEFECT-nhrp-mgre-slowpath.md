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
| `.spathintf` | RX 13 / TX 13 — the packets do reach the dataplane |
| dataplane `tun0` | **tx_packets 0** |
| dataplane `dp0s3` | 11 tx / 11 rx, i.e. the pings and nothing else |

So the packet crosses into the dataplane and is never encapsulated.

## Cause

Two pieces of code, and the gap is between them.

`shadow.c`, handling a packet the kernel sent on a tunnel, takes the peer's
NBMA address from the metadata mark and from nowhere else:

```c
if (!(meta.flags & TUN_META_FLAG_MARK))
        dst = NULL;
else {
        dst_addr = meta.mark;
        dst = mgre_nbma_to_tun_addr(ifp, &dst_addr);
}
...
gre_tunnel_fragment_and_send(host_ifp, ifp, dst, m, ntohs(pi.proto));
```

`meta.mark` is `skb->mark`, carried across the tun device by the Vyatta
`IFF_META_HDR` extension. The kernel's multipoint GRE transmit path fills it in
after resolving the **neighbour entry** that holds the NBMA address.

`gre.c`, encapsulating, then does this:

```c
if (sc->scg_multipoint && nxt_ip) {
        /* look the peer up by tunnel address */
} else {
        outer_ip = &greinfo->iph;
        t_vrfid = greinfo->t_vrfid;
}
```

A multipoint tunnel with no `nxt_ip` falls into the `else` and uses the
tunnel's own header — whose destination, for multipoint, is unset:

```
dataplane tun0:  source=201.1.1.1 dest=0.0.0.0 flags=0
```

The packet is encapsulated to 0.0.0.0 and goes nowhere. Nothing is logged and
no error counter moves, which is why this looked like a daemon fault.

## Why it cannot bootstrap

`ip neigh show dev tun0` is empty on both routers throughout. That is not a
bug: FRR's nhrpd sends its own control packets through an `AF_PACKET` socket
with the NBMA address in the link-layer destination, deliberately bypassing the
neighbour table, because the neighbour entry is the thing NHRP exists to create.

So the only channel that can carry a per-packet NBMA destination into the
dataplane is populated from a neighbour entry, and NHRP's bootstrap packets
necessarily precede any neighbour entry. Registration can never succeed, and
no amount of retrying changes that.

## What a fix has to do

Give the slow path an NBMA destination for a packet that has no neighbour
entry. The link-layer destination nhrpd already sets is the natural source —
on a GRE device the hardware address *is* the four-byte NBMA address — but
`spath_receive()` reads the frame as L3 plus `struct tun_meta` and the
link-layer destination is not among the fields carried across.

Two candidate directions, neither yet attempted:

1. Carry the link-layer destination across the tun device alongside `mark`,
   and use it in `shadow.c` when the mark is absent. Touches the kernel
   extension as well as the dataplane.
2. Have the dataplane resolve the destination itself for `ETH_P_NHRP`, from
   the tunnel's NHS configuration. Confines the change to the dataplane but
   duplicates knowledge that belongs to nhrpd.

Independently of either, the `else` branch in `gre_tunnel_encap()` should not
silently encapsulate a multipoint packet to `0.0.0.0`. Dropping it and counting
an output error would have made this a five-minute diagnosis instead of a
four-hour one.

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
