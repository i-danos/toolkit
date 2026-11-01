#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-only
"""Drive shim's MokManager over the serial console socket, reading what it prints.

Usage: mokmanager-drive.py <console.sock> <password> <outdir> [--wait SECONDS]

MokManager's menus are text on the firmware console; with the serial console that is a byte stream of text and
cursor escapes, which is what is read here (no screenshots). It sends keys only after seeing the text that
precedes them, never on a timer, and every wait has a deadline. Walks: "Press any key" -> Enroll MOK ->
View key 0 -> Continue -> Yes -> password characters -> Reboot. Writes <outdir>/mokmanager.raw (the bytes) and
<outdir>/mokmanager-screen.txt (escapes stripped, one screen section per step) and exits 0 only if the whole
walk completed; any screen it cannot read exits non-zero naming the step.
"""
import re, socket, sys, time

sock, password, out = sys.argv[1], sys.argv[2], sys.argv[3]
wait = int(sys.argv[sys.argv.index("--wait") + 1]) if "--wait" in sys.argv else 300
DOWN, ENTER = b"\x1b[B", b"\r"

s = socket.socket(socket.AF_UNIX); s.connect(sock); s.settimeout(1)
raw = b""
mark = 0
sections = []

def pump(sec):
    global raw
    end = time.time() + sec
    while time.time() < end:
        try:
            d = s.recv(65536)
            if not d:
                break
            raw += d
        except socket.timeout:
            pass

def text(b):
    t = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"\n", b).decode("utf-8", "replace").replace("\r", "")
    return re.sub(r"\n[ \t]*(?=\n)", "", t)

def wait_for(pat, what, timeout=60):
    global mark
    end = time.time() + timeout
    while time.time() < end:
        pump(1)
        t = text(raw[mark:])
        m = re.search(pat, t)
        if m:
            sections.append("=== %s ===\n%s" % (what, t))
            mark = len(raw)
            return m
    sections.append("=== %s: NOT SEEN (waited %ds for %r) ===\n%s" % (what, timeout, pat, text(raw[mark:])[-2000:]))
    fin(1, what)

def fin(rc, what=""):
    open(out + "/mokmanager.raw", "wb").write(raw)
    open(out + "/mokmanager-screen.txt", "w").write("\n".join(sections))
    if rc:
        print("MOKMANAGER-FAIL at step: %s" % what)
    sys.exit(rc)

wait_for(r"Press any key to perform MOK management", "the MokManager banner", wait)
s.sendall(b" ")
wait_for(r"Enroll MOK", "the main menu")
s.sendall(DOWN); time.sleep(0.5); s.sendall(ENTER)
wait_for(r"View key 0", "the Enroll MOK menu")
s.sendall(ENTER)
wait_for(r"SHA1 Fingerprint|Fingerprint", "View key 0")
pump(2)
sections.append("=== View key 0 (settled) ===\n" + text(raw[mark:])); mark = len(raw)
s.sendall(ENTER)
wait_for(r"Continue", "back at the key list")
s.sendall(DOWN); time.sleep(0.5); s.sendall(ENTER)
wait_for(r"Enroll the key", "the confirmation")
s.sendall(DOWN); time.sleep(0.5); s.sendall(ENTER)
for _ in range(10):
    m = wait_for(r"[Ee]nter password character (\d+)|Password:|Reboot|Perform MOK management", "the password prompt")
    if m.group(1):
        i = int(m.group(1)) - 1
        s.sendall(password[i].encode()); time.sleep(0.3); s.sendall(ENTER)
        continue
    if "Password" in m.group(0):
        s.sendall(password.encode()); time.sleep(0.3); s.sendall(ENTER)
        continue
    break
pump(2)
t = text(raw[mark:])
sections.append("=== after the password ===\n" + t); mark = len(raw)
if re.search(r"Reboot", t):
    s.sendall(ENTER)
    pump(3)
fin(0)
