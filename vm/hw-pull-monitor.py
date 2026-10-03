#!/usr/bin/env python3
"""Watch what a pulled cable does on the physical bench, one layer at a time.

Samples, on each of two routers every ~0.2 s: the kernel's next hop (`ip route get`), the data
plane's own next hop (`vplsh route lookup`), and the state of the neighbour entry for the dead
next hop. In parallel a 10 Hz ping runs from this host to an end host, so the same timeline carries
the loss a user would see.

Why three views: the routing daemons, the kernel table and the data plane's table are three
different things that can disagree. Measuring only router-originated traffic reads the kernel
table and says nothing about forwarded traffic, which uses the data plane's (2026-10-03: the kernel
lagged 8 s to over 68 s while forwarded traffic lost under 1 s). Each line is logged only when a
router's sample changes.

The neighbour state is matched against the kernel's state names. An earlier version took the last
word of `ip neigh show`, which is the routing protocol tag ("zebra"), not the state, and silently
recorded nothing useful.

Usage: hw-pull-monitor.py [seconds]    writes ./transit_events.log
Edit ROUTERS and PING_TARGET for the topology; see hw_ssh.py for how routers are reached.
"""
import re
import subprocess
import sys
import threading
import time

import hw_ssh as ssh

DUR = int(sys.argv[1]) if len(sys.argv) > 1 else 600
PING_TARGET = "192.168.75.4"
# name -> reach address, destination the router forwards towards, dead next hop on the pulled link,
# and that link's interface name on this router
ROUTERS = {
    "R1": dict(ip="192.168.71.2", dst="192.168.75.4", deadnh="192.168.72.3", ifc="dp0p2s0"),
    "R2": dict(ip="192.168.73.3", dst="192.168.71.1", deadnh="192.168.72.2", ifc="dp0p2s0"),
}
STATES = "INCOMPLETE|REACHABLE|STALE|DELAY|PROBE|FAILED|PERMANENT|NOARP"

LOG = open("transit_events.log", "w", buffering=1)
T0 = time.time()
stop = False


def log(*a):
    LOG.write("%.2f %s\n" % (time.time() - T0, " ".join(str(x) for x in a)))


def streamer(name):
    c = ROUTERS[name]
    _, r = ssh.connect(c["ip"])
    loop = (
        "while true; do "
        "k=$(ip route get %(dst)s 2>/dev/null | head -1 | sed -n 's/.* dev \\([a-z0-9]*\\).*/\\1/p'); "
        "d=$(/opt/vyatta/bin/vplsh -l -c 'route lookup %(dst)s' 2>/dev/null "
        "| grep -o '\"ifname\":\"[a-z0-9]*\"' | sed 's/\"ifname\":\"//;s/\"//' | tr '\\n' ','); "
        "nb=$(ip neigh show %(deadnh)s dev %(ifc)s 2>/dev/null | grep -o -E '" + STATES + "' | head -1); "
        "echo \"S kern=${k:-none} dp=${d:-none} neigh=${nb:-none}\"; sleep 0.2; done"
    ) % c
    ch = r.get_transport().open_session()
    ch.exec_command("echo %s | sudo -S -p '' sh -c '%s'" % (ssh.PASSWORD, loop.replace("'", "'\\''")))
    buf, last = "", None
    while not stop:
        if ch.recv_ready():
            buf += ch.recv(4096).decode()
        else:
            time.sleep(0.05)
        while "\n" in buf:
            line, buf = buf.split("\n", 1)
            m = re.match(r"S (.*)", line)
            if m and m.group(1) != last:
                log(name, m.group(1))
                last = m.group(1)
    ch.close()


def pinger():
    n = DUR * 10
    out = subprocess.run(["ping", "-D", "-O", "-i", "0.1", "-c", str(n), PING_TARGET],
                         capture_output=True, text=True).stdout
    recv = {int(x) for x in re.findall(r"icmp_seq=(\d+) ttl", out)}
    windows = []
    for s in sorted(set(range(1, n + 1)) - recv):
        if windows and s == windows[-1][1] + 1:
            windows[-1][1] = s
        else:
            windows.append([s, s])
    log("PING sent", n, "received", len(recv), "loss windows (start_s, secs):",
        [(round(a * 0.1, 1), round((b - a + 1) * 0.1, 1)) for a, b in windows if b - a + 1 >= 2])


if __name__ == "__main__":
    for name in ROUTERS:
        threading.Thread(target=streamer, args=(name,), daemon=True).start()
    p = threading.Thread(target=pinger)
    p.start()
    p.join()
    stop = True
    time.sleep(1)
    log("DONE")
