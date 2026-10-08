#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""First-boot provisioning of a physical DANOS box over its serial console.

A freshly installed box has every dataplane port administratively down and a
login that lands in the vbash sandbox (no sudo, systemctl or vplsh). Doing the
same handful of CLI steps by hand on each of several identical machines is
slow and, worse, drifts: one box ends up with a different hostname scheme or
without superuser. This does them identically and reads the result back.

What it sets, and why each one:

  host-name          every install comes up as "node"; two of them on one
                     bench are indistinguishable in logs and prompts
  level superuser    the installer's account is a sandbox. Without this,
                     "systemctl is-active" answers "Host is down" for a healthy
                     box -- a false negative, not a measurement. Takes effect
                     only on a fresh login, which is why the script logs out
                     and verifies with a second login rather than trusting the
                     commit.
  management address static, on one dataplane port. Not DHCP: two DHCP clients
                     waiting on each other left a port reporting "Link Down"
                     with the LED lit (DEFECTS.md, defect 14, real-hardware
                     note).
  ssh                so everything after this can leave the one serial cable.

Usage: hw-provision.py --hostname R2 --mgmt-if dp0p1s0 --mgmt-addr 192.168.71.3/24

It never guesses a password: the account and password are arguments, and a
rejected login stops the run.
"""
import argparse
import re
import sys
import time

import serial

ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07")
OP_PROMPT = re.compile(r"\w+@[\w.-]+:[^\n]*\$ $")
CFG_PROMPT = re.compile(r"\w+@[\w.-]+# $")


class Console:
    def __init__(self, dev, baud):
        self.s = serial.Serial(dev, baud, timeout=0.3)

    def read_until(self, pattern, timeout):
        """Read until the tail of the buffer matches, or the timeout passes.

        Matching on the prompt rather than sleeping a fixed time matters
        here: a commit takes anywhere from a few seconds to over half a
        minute, and a command typed while it runs is queued behind it,
        which reads as a successful run that did nothing.
        """
        buf = ""
        end = time.time() + timeout
        while time.time() < end:
            buf += ANSI.sub("", self.s.read(4096).decode("latin1"))
            if pattern.search(buf.replace("\r", "")):
                return buf, True
        return buf, False

    def send(self, line, pattern, timeout=15):
        self.s.write(line.encode() + b"\r\n")
        return self.read_until(pattern, timeout)

    def login(self, user, password):
        self.s.reset_input_buffer()
        self.s.write(b"\x03\r\n")
        buf, _ = self.read_until(re.compile(r"(login: |\$ |# )$"), 5)
        tail = buf.replace("\r", "")
        if tail.rstrip().endswith("login:"):
            self.s.write(user.encode() + b"\r\n")
            self.read_until(re.compile(r"Password: $"), 5)
            self.s.write(password.encode() + b"\r\n")
            buf, ok = self.read_until(re.compile(r"(\$ |login: )$"), 20)
            if "incorrect" in buf or not OP_PROMPT.search(buf.replace("\r", "")):
                return False
        return True

    def logout(self):
        self.s.write(b"exit\r\n")
        self.read_until(re.compile(r"login: $"), 5)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--serial", default="/dev/ttyUSB0")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--user", default="admin")
    ap.add_argument("--password", default="admin")
    ap.add_argument("--hostname", required=True)
    ap.add_argument("--mgmt-if", required=True)
    ap.add_argument("--mgmt-addr", required=True)
    a = ap.parse_args()

    c = Console(a.serial, a.baud)
    if not c.login(a.user, a.password):
        sys.exit(f"login as {a.user} refused; not guessing another password")

    steps = [
        f"set system host-name {a.hostname}",
        f"set system login user {a.user} level superuser",
        f"set interfaces dataplane {a.mgmt_if} address {a.mgmt_addr}",
        "set service ssh",
    ]
    c.send("configure", CFG_PROMPT)
    for st in steps:
        out, ok = c.send(st, CFG_PROMPT)
        if not ok or "rror" in out:
            sys.exit(f"configuration step failed: {st}\n{out}")
    out, ok = c.send("commit", CFG_PROMPT, timeout=120)
    if not ok or "ailed" in out or "rror" in out:
        sys.exit(f"commit failed or timed out:\n{out}")
    c.send("save", CFG_PROMPT, timeout=30)
    c.send("exit", OP_PROMPT)

    # A fresh login is what picks up the new group; reading back through the
    # old session would still show the sandbox.
    c.logout()
    if not c.login(a.user, a.password):
        sys.exit("second login failed after provisioning")
    out, _ = c.send("id", OP_PROMPT)
    if "vyattasu" not in out:
        sys.exit(f"{a.user} is not in vyattasu after re-login:\n{out}")
    out, _ = c.send("show interfaces", OP_PROMPT, timeout=20)
    print(out)
    print(f"provisioned {a.hostname}: {a.mgmt_if} {a.mgmt_addr}, superuser, ssh")


if __name__ == "__main__":
    main()
