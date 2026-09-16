#!/usr/bin/env python3
"""Sit between zebra and brokerd and lose exactly the messages you name.

Why this exists: proving that a route-level repair works needs a route that is
missing from the data plane while the FPM session is up, and this system has no
honest way to make one. The only lever is an FPM session bounce, and a bounce
runs zebra's full RIB walk -- which performs the repair before the primitive
being tested is ever called. Manufacturing the drift from inside brokerd was
the other option and is worse: it puts a test hook in the one component whose
whole value here is that it holds no routing state, and it makes the loss come
from the deliverer rather than from the delivery.

So the loss happens on the wire, between the two, where a real delivery failure
would happen:

    zebra --(2621)--> fpm-filter --(2620)--> brokerd

brokerd is untouched and still listens on 2620. zebra is pointed at this with
"fpm address 127.0.0.1 port 2621", which is a configuration change, not a code
one.

Framing: a 4-byte FPM header -- version, msg_type, msg_len in network order,
length inclusive of the header -- followed by a netlink message. Dropping has
to be done on message boundaries, so every frame is parsed even when it is
passed through untouched; a byte-oriented filter would corrupt the stream the
first time a prefix matched.

Only RTM_NEWROUTE frames carrying the named prefix are eligible, and each
--drop is honoured once. Everything else is forwarded verbatim, including
frames this program does not understand: an unknown message type is not a
reason to interfere with it.

Usage:
    fpm-filter.py --listen 2621 --connect 127.0.0.1:2620 \
                  --drop 10.91.1.0/24 [--drop ...] [--state /tmp/f.json]
"""

import argparse
import json
import os
import selectors
import socket
import struct
import sys
import threading

FPM_HDR = struct.Struct("!BBH")          # version, msg_type, msg_len
FPM_HDR_LEN = 4
FPM_MSG_TYPE_NETLINK = 1

NLMSG_HDR = struct.Struct("=IHHII")      # len, type, flags, seq, pid
NLMSG_HDR_LEN = 16
RTM_NEWROUTE = 24
RTM_DELROUTE = 25

RTMSG = struct.Struct("=BBBBBBBBI")      # family,dst_len,src_len,tos,table,
                                         # protocol,scope,type,flags
RTMSG_LEN = 12
RTA_DST = 1


def rtattrs(buf):
    """Walk the rtattr list, yielding (type, payload)."""
    off = 0
    while off + 4 <= len(buf):
        rta_len, rta_type = struct.unpack_from("=HH", buf, off)
        if rta_len < 4 or off + rta_len > len(buf):
            return
        yield rta_type, buf[off + 4:off + rta_len]
        off += (rta_len + 3) & ~3


def route_of(payload):
    """The (prefix, length) a netlink route message is about, or None.

    None means "this frame is not a route message I can read", which is a
    different thing from "this frame is about no prefix" -- both are forwarded,
    but only one of them is a parsing failure worth counting.
    """
    if len(payload) < NLMSG_HDR_LEN + RTMSG_LEN:
        return None
    _, nlmsg_type, _, _, _ = NLMSG_HDR.unpack_from(payload, 0)
    if nlmsg_type not in (RTM_NEWROUTE, RTM_DELROUTE):
        return None

    family, dst_len = struct.unpack_from("=BB", payload, NLMSG_HDR_LEN)
    attrs = payload[NLMSG_HDR_LEN + RTMSG_LEN:]
    for rta_type, val in rtattrs(attrs):
        if rta_type != RTA_DST:
            continue
        try:
            if family == socket.AF_INET and len(val) == 4:
                return "%s/%d" % (socket.inet_ntop(socket.AF_INET, val), dst_len)
            if family == socket.AF_INET6 and len(val) == 16:
                return "%s/%d" % (socket.inet_ntop(socket.AF_INET6, val), dst_len)
        except (OSError, ValueError):
            return None
    # A route message with no RTA_DST is a default route.
    if family == socket.AF_INET:
        return "0.0.0.0/%d" % dst_len
    if family == socket.AF_INET6:
        return "::/%d" % dst_len
    return None


class Stats(object):
    def __init__(self):
        self.lock = threading.Lock()
        self.frames = 0
        self.routes = 0
        self.dropped = []
        self.unparsed = 0

    def snapshot(self):
        with self.lock:
            return {"frames": self.frames, "route_frames": self.routes,
                    "dropped": list(self.dropped), "unparsed": self.unparsed}


def recv_exactly(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def pump(src, dst, want_drop, stats, state_path):
    """Forward frames from src to dst, losing the ones named in want_drop."""
    while True:
        hdr = recv_exactly(src, FPM_HDR_LEN)
        if hdr is None:
            return
        version, msg_type, msg_len = FPM_HDR.unpack(hdr)
        if msg_len < FPM_HDR_LEN or msg_len > 65535:
            # Not something this program can frame. Forwarding the header and
            # then guessing would desynchronise the stream, so stop instead:
            # a filter that corrupts the session proves nothing about repair.
            sys.stderr.write("fpm-filter: bad frame length %d, closing\n" % msg_len)
            return
        body = recv_exactly(src, msg_len - FPM_HDR_LEN)
        if body is None:
            return

        with stats.lock:
            stats.frames += 1

        drop = False
        if version == 1 and msg_type == FPM_MSG_TYPE_NETLINK:
            pfx = route_of(body)
            if pfx is None:
                with stats.lock:
                    stats.unparsed += 1
            else:
                with stats.lock:
                    stats.routes += 1
                with stats.lock:
                    if pfx in want_drop and want_drop[pfx] > 0:
                        want_drop[pfx] -= 1
                        stats.dropped.append(pfx)
                        drop = True

        if drop:
            sys.stderr.write("fpm-filter: dropped %s\n" % pfx)
            sys.stderr.flush()
            if state_path:
                with open(state_path, "w") as f:
                    json.dump(stats.snapshot(), f)
            continue

        dst.sendall(hdr + body)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", type=int, default=2621)
    ap.add_argument("--connect", default="127.0.0.1:2620")
    ap.add_argument("--drop", action="append", default=[],
                    help="prefix to lose, once each; repeatable")
    ap.add_argument("--state", help="write a JSON summary here on every drop")
    args = ap.parse_args()

    host, _, port = args.connect.rpartition(":")
    want_drop = {}
    for p in args.drop:
        want_drop[p] = want_drop.get(p, 0) + 1
    stats = Stats()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", args.listen))
    srv.listen(1)
    sys.stderr.write("fpm-filter: listening on %d, forwarding to %s, "
                     "will drop %s\n" % (args.listen, args.connect,
                                         args.drop or "nothing"))
    sys.stderr.flush()

    while True:
        up, _ = srv.accept()
        try:
            down = socket.create_connection((host, int(port)))
        except OSError as e:
            sys.stderr.write("fpm-filter: cannot reach brokerd: %s\n" % e)
            up.close()
            continue
        sys.stderr.write("fpm-filter: session up\n")
        sys.stderr.flush()
        try:
            pump(up, down, want_drop, stats, args.state)
        except OSError as e:
            sys.stderr.write("fpm-filter: session error: %s\n" % e)
        finally:
            for s in (up, down):
                try:
                    s.close()
                except OSError:
                    pass
            snap = stats.snapshot()
            sys.stderr.write("fpm-filter: session down, %s\n" % json.dumps(snap))
            sys.stderr.flush()
            if args.state:
                with open(args.state, "w") as f:
                    json.dump(snap, f)


if __name__ == "__main__":
    main()
