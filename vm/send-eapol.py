#!/usr/bin/env python3
"""Send EAPOL-Start frames out one interface, straight down a raw socket.

Usage: send-eapol.py <interface> <count> [<destination-mac>]

Shipped as a file rather than piped in as a one-liner. An inline python sender
sent through ssh into vbash once lost its quoting and produced no output, no
error, and counters that were zero because nothing had been sent -- which reads
exactly like the frames being dropped.

The destination defaults to the PAE group address 01:80:c2:00:00:03, which is
what a supplicant sends its first frame to. Note what that costs when nothing
is listening: local_packet_filter() in shadow_receive.c drops a multicast the
interface has not joined, so a punted EAPOL frame addressed to the group still
never reaches the kernel unless hostapd (or something else) has joined it. Pass
the authenticator's own MAC to test the punt on its own -- a real supplicant
unicasts to it after the first exchange, so this is not a contrived frame.

The body is the smallest valid EAPOL frame: version 2, type 1 (EAPOL-Start),
length 0.
"""

import socket
import struct
import sys

ETH_P_PAE = 0x888E
PAE_GROUP = b"\x01\x80\xc2\x00\x00\x03"


def main():
    if len(sys.argv) not in (3, 4):
        print("usage: send-eapol.py <interface> <count> [<destination-mac>]",
              file=sys.stderr)
        return 2
    ifname, count = sys.argv[1], int(sys.argv[2])
    if len(sys.argv) == 4:
        dst = bytes(int(b, 16) for b in sys.argv[3].split(":"))
        if len(dst) != 6:
            print("destination must be six hex octets", file=sys.stderr)
            return 2
    else:
        dst = PAE_GROUP

    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_PAE))
    s.bind((ifname, 0))
    src = s.getsockname()[4]

    frame = dst + src + struct.pack("!H", ETH_P_PAE) + b"\x02\x01\x00\x00"
    # Pad to the 60-byte minimum so nothing on the path drops a runt and the
    # count being measured is the count that was sent.
    frame += b"\x00" * (60 - len(frame))

    sent = 0
    for _ in range(count):
        s.send(frame)
        sent += 1
    s.close()
    print("sent %d" % sent)
    return 0


if __name__ == "__main__":
    sys.exit(main())
