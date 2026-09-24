#!/usr/bin/env python3
"""Wait for GRUB's menu to appear in a UEFI VM's serial log, then pick an entry.

Usage: grub-pick.py <run-dir> <entry-index> [--marker TEXT] [--wait SECONDS]

GRUB's menu is read from <run-dir>/serial.log (uefi-vm.sh writes every byte
there from the first), and the entry is chosen with the QEMU monitor's sendkey,
so it needs neither the serial port nor a display. Prints one line and exits 0
once the entry has been selected, 3 if the menu never appeared within --wait.

The wait defaults to 15 minutes because qemu on this host has taken seven
minutes to run its first instruction; a short timeout there reads as "the chain
refused to boot" and is wrong.
"""
import argparse
import re
import socket
import sys
import time

ap = argparse.ArgumentParser()
ap.add_argument("run")
ap.add_argument("entry", type=int)
ap.add_argument("--marker", default="GNU GRUB")
ap.add_argument("--wait", type=int, default=900)
a = ap.parse_args()

log, mon = a.run + "/serial.log", a.run + "/monitor.sock"


def text():
    try:
        raw = open(log, "rb").read().decode(errors="replace")
    except OSError:
        return ""
    return re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", raw)


m = socket.socket(socket.AF_UNIX)
for _ in range(60):
    try:
        m.connect(mon)
        break
    except OSError:
        time.sleep(1)
m.settimeout(3)


def hmp(cmd):
    m.sendall((cmd + "\n").encode())
    time.sleep(0.25)
    try:
        m.recv(65536)
    except socket.timeout:
        pass


t0 = time.time()
while time.time() - t0 < a.wait:
    t = text()
    if a.marker in t and "live-" in t:
        time.sleep(1.5)
        for _ in range(a.entry):
            hmp("sendkey down")
            time.sleep(0.3)
        hmp("sendkey ret")
        print("selected entry %d after %ds" % (a.entry, time.time() - t0))
        sys.exit(0)
    time.sleep(2)
print("GRUB menu never appeared in %ds" % a.wait)
sys.exit(3)
