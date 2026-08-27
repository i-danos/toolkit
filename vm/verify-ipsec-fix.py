#!/usr/bin/env python3
"""Check whether configuring IPsec still crashes the dataplane.

vyatta-dataplane before 3.14.27 segfaulted the moment an outbound packet hit a
policy check, because the controller XFRM path staged rules into an rldb
transaction and never committed it, leaving npf_rte_acl_trie_match() to hand an
unbuilt ACL context to rte_acl_classify(). The dataplane then crash-looped,
which is unusually hard to recognise: the ports stay listed with their
addresses, so it reads as a routing or cabling problem rather than a dead
forwarding plane.

Each check below is a discriminator -- it comes out differently depending on
whether the fix is in. The first two look straight at the dataplane, the rest at
the consequences of it having been down, so a pass means the crash is gone
rather than merely relocated.

Run it after configuring IPsec on the topology (the suite's first three test
cases do that), from a host that can reach the management addresses.

Usage: verify-ipsec-fix.py [<r1-ip> <r2-ip> <r3-ip>]
"""

import re
import sys

import paramiko

DEFAULT = ["192.168.203.155", "192.168.203.156", "192.168.203.157"]
WRAP = "/opt/vyatta/bin/vyatta-op-cmd-wrapper"


def sh(ip, cmd, timeout=60):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(ip, 22, "vyatta", "vyatta", timeout=20)
    _, out, err = c.exec_command(cmd, timeout=timeout)
    text = (out.read().decode() + err.read().decode()).strip()
    c.close()
    return text


def main():
    ips = sys.argv[1:4] if len(sys.argv) >= 4 else DEFAULT
    names = ["R1", "R2", "R3"]
    ok = True

    print("== 1. dataplane state ==")
    for n, ip in zip(names, ips):
        state = sh(ip, "systemctl is-active vyatta-dataplane")
        good = state == "active"
        ok &= good
        print(f"  {'PASS' if good else 'FAIL'}  {n} {state}"
              f"{'' if good else '   (activating means it is restarting)'}")

    print("\n== 2. crash count ==")
    for n, ip in zip(names, ips):
        # grep -c prints 0 and exits 1 when it matches nothing, so a trailing
        # "|| echo 0" appends a second line rather than substituting one.
        crashes = sh(ip, "sudo -n journalctl -u vyatta-dataplane --no-pager 2>/dev/null "
                         "| grep -c core-dump; true").strip().split("\n")[0]
        good = crashes in ("0", "")
        ok &= good
        print(f"  {'PASS' if good else 'FAIL'}  {n} {crashes} core dumps")

    print("\n== 3. dataplane ports moving packets ==")
    for n, ip in zip(names, ips):
        counts = sh(ip, "for i in /sys/class/net/dp0s*; do "
                        "echo -n \"$(basename $i)=$(cat $i/statistics/rx_packets)/"
                        "$(cat $i/statistics/tx_packets) \"; done")
        # Every port reading 0/0 is the signature of a dataplane that never ran.
        dead = counts and all(p.split("=")[1] == "0/0" for p in counts.split() if "=" in p)
        ok &= not dead
        print(f"  {'FAIL' if dead else 'PASS'}  {n} {counts}")

    print("\n== 4. links pass traffic ==")
    for src, dst, addr in [("R1", "R2", "140.1.1.4"), ("R3", "R2", "150.1.1.4"),
                           ("R2", "R3", "150.1.1.3")]:
        ip = ips[names.index(src)]
        res = sh(ip, f"ping -c3 -W2 {addr} 2>&1 | tail -2 | head -1", timeout=40)
        # "100% packet loss" contains "0% packet loss" as a substring, so match
        # the whole field: anything but zero loss is a failure.
        m = re.search(r"(\d+)% packet loss", res)
        good = m is not None and m.group(1) == "0"
        ok &= good
        print(f"  {'PASS' if good else 'FAIL'}  {src}->{dst} {addr}: {res.strip()[:70]}")

    print("\n== 5. IPsec SA ==")
    for n, ip in [("R1", ips[0]), ("R3", ips[2])]:
        sa = sh(ip, f"{WRAP} show vpn ipsec sa 2>/dev/null | head -6")
        warn = "deprecated" in sa
        print(f"  {'FAIL' if warn else 'INFO'}  {n}: "
              f"{'Perl warnings still present' if warn else (sa.replace(chr(10), ' | ')[:90] or '(no SA)')}")
        ok &= not warn

    print("\n" + ("  ALL CHECKS PASSED" if ok else "  SOME CHECKS FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
