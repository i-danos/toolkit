#!/usr/bin/env python3
"""Send IPv6 multicast out a chosen interface.

Usage: send6.py <group> <interface> <count>

IPV6_MULTICAST_IF takes an interface index, not an address, which is the one
real difference from the IPv4 sender.
"""
import socket
import struct
import sys
import time

group, iface, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_HOPS, 16)
s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF,
             struct.pack("I", socket.if_nametoindex(iface)))
for _ in range(count):
    s.sendto(b"6" * 200, (group, 5000))
    time.sleep(0.001)
print("sent", count)
