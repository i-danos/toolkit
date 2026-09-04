#!/usr/bin/env python3
"""Send IPv4 multicast from a chosen source address.

Usage: send4.py <group> <source-address> <count>

Kept as a file because the inline form did not survive the trip through the
driving shell, ssh and vbash: it produced no output and no error, and the run
carried on to counters that were zero because nothing had been sent.
"""
import socket
import sys
import time

group, source, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 16)
s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(source))
for _ in range(count):
    s.sendto(b"S" * 200, (group, 5000))
    time.sleep(0.001)
print("sent", count)
