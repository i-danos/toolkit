#!/usr/bin/env python3
"""Send an exact number of ARP frames out one interface, down a raw socket.

Usage: send-arp.py <interface> <sender-ip> <target-ip> <count> [kind]

  kind = request  ARP request, broadcast            (default)
         reply    ARP reply, to an unknown unicast
         other    a non-ARP broadcast of the same size

Counting is the whole point, which is why this exists instead of ping. A ping
to an unresolved address does not send one ARP request: the kernel's neighbour
state machine sends up to mcast_solicit of them, backs off, and then caches the
failure, so the number of requests that reach the bridge is somewhere between
one and three and is not the same on the second attempt. A counter asserted
against "one ping" therefore has to be asserted loosely, and a loose assertion
cannot tell a counter that counts once per request from one that counts twice.

Shipped as a file rather than piped in as a one-liner, for the reason
send-eapol.py records: an inline python sender sent through ssh into vbash once
lost its quoting and produced no output, no error, and counters that were zero
because nothing had been sent -- which reads exactly like the frames being
dropped.

The two non-request kinds are there to check what the counter does NOT count.
"reply" is an ARP frame that is not a request, addressed to a MAC the bridge
has not learned so that it floods; "other" is a broadcast that is not ARP at
all. Both take the same path through the bridge as a flooded request, so if
either moves the counters the gate in front of them is wrong.

Frames are padded to the 60-byte Ethernet minimum. An unpadded ARP is 42 bytes
and the dataplane checks the length before reading the body, so padding here
keeps the test measuring the gate rather than the driver's padding behaviour.
"""

import socket
import struct
import sys
import time

ETH_P_ARP = 0x0806
ETH_P_OTHER = 0x88B5  # IEEE Std 802 local experimental Ethertype 1
BROADCAST = b"\xff" * 6
UNKNOWN_UNICAST = b"\x02\x00\x00\x00\x00\x99"
MIN_FRAME = 60


def hwaddr(ifname):
    with open("/sys/class/net/%s/address" % ifname) as f:
        return bytes(int(b, 16) for b in f.read().strip().split(":"))


def arp_frame(src_mac, dst_mac, sender_ip, target_ip, op):
    eth = struct.pack("!6s6sH", dst_mac, src_mac, ETH_P_ARP)
    # A request asks an unknown target, so its target MAC is zero; a reply
    # carries the sender's own MAC, which is what makes it a reply.
    target_mac = b"\x00" * 6 if op == 1 else src_mac
    arp = struct.pack(
        "!HHBBH6s4s6s4s",
        1, 0x0800, 6, 4, op,
        src_mac, socket.inet_aton(sender_ip),
        target_mac, socket.inet_aton(target_ip),
    )
    return eth + arp


def other_frame(src_mac):
    eth = struct.pack("!6s6sH", BROADCAST, src_mac, ETH_P_OTHER)
    return eth + b"\x00" * 28


def main():
    ifname, sender_ip, target_ip, count = sys.argv[1:5]
    kind = sys.argv[5] if len(sys.argv) > 5 else "request"
    count = int(count)

    src_mac = hwaddr(ifname)
    if kind == "request":
        frame = arp_frame(src_mac, BROADCAST, sender_ip, target_ip, 1)
    elif kind == "reply":
        frame = arp_frame(src_mac, UNKNOWN_UNICAST, sender_ip, target_ip, 2)
    elif kind == "other":
        frame = other_frame(src_mac)
    else:
        sys.exit("unknown kind %r" % kind)

    frame += b"\x00" * max(0, MIN_FRAME - len(frame))

    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
    s.bind((ifname, 0))
    for _ in range(count):
        s.send(frame)
        time.sleep(0.05)
    print("sent", count, kind)


main()
