#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-only
"""Judge one part of the MOK enrolment run from the files verify-sb-mok-flow.sh left.

Usage: mok-judge.py <outdir> <obs|control> queue|view|enrolled

Exit 0 only if the part holds; every line it prints is the evidence. The expected values come from openssl run on
the certificate file itself (obs-signer.pem / control.pem), never from what the guest or MokManager said.
"""
import re, subprocess, sys

out, who, part = sys.argv[1:4]
pem = out + ("/obs-signer.pem" if who == "obs" else "/control.pem")


def ssl(*a):
    return subprocess.run(["openssl", "x509", "-in", pem, "-noout", *a], capture_output=True, text=True).stdout.strip()


def rd(n):
    try:
        return open(out + "/" + n, errors="replace").read().replace("\r", "")
    except OSError:
        return ""


sha1 = ssl("-fingerprint", "-sha1").split("=", 1)[1].lower()
serial = ssl("-serial").split("=", 1)[1].lower().lstrip("0")
nm = lambda k: set(x.strip() for x in ssl("-" + k, "-nameopt", "sep_comma_plus_space,sname").split("=", 1)[1].split(", "))
print("expected sha1=%s serial=%s" % (sha1, serial))
ok = True


def check(label, cond, detail=""):
    global ok
    ok = ok and cond
    print("%s=%s %s" % (label, "yes" if cond else "NO", detail))


if part == "queue":
    files = ["import.out", "import-ignore-keyring.out", "list-new.out", "list-new-ignore-keyring.out"] if who == "obs" else ["control-import.out", "control-list-new.out"]
    for f in files:
        for l in rd(f).splitlines():
            if l.strip() and not l.startswith(("$", "echo", "vyatta@")):
                print("%s: %s" % (f, l.strip()))
    fps = []
    for f in files:
        if "list-new" in f:
            fps += [x.lower() for x in re.findall(r"SHA1 Fingerprint: ([0-9a-fA-F:]{59})", rd(f))]
    check("queued", sha1 in fps, "(queued fingerprints: %s)" % (",".join(fps) or "none"))
elif part == "view":
    scr = rd("mokmanager-screen.txt")
    m = re.search(r"=== View key 0 ===\n(.*?)\n=== ", scr, re.S)
    if not m:
        print("MokManager View key 0 screen: not captured (%s)" % (rd("mokmanager-drive.out").strip() or "no driver output"))
        sys.exit(1)
    t = re.sub(r"[│┌┐└┘─]", "", m.group(1))
    lines = [l.strip() for l in t.splitlines()]

    def sec(k):
        if "[%s]" % k not in lines:
            return []
        r = []
        for l in lines[lines.index("[%s]" % k) + 1:]:
            if l.startswith("["):
                break
            if l:
                r.append(l)
        return r
    s_serial = "".join(sec("Serial Number")).replace(":", "").lower().lstrip("0")
    s_fp = "".join(sec("Fingerprint")).replace(" ", "").lower()
    print("screen serial=%s fingerprint=%s" % (s_serial, s_fp))
    check("serial-matches-openssl", s_serial == serial)
    check("sha1-fingerprint-matches-openssl", s_fp == sha1.replace(":", ""))
    for k in ("Issuer", "Subject"):
        got = set(x.strip() for x in " ".join(sec(k)).split(","))
        check(k.lower() + "-matches-openssl", got == nm(k.lower()), "screen=%s openssl=%s" % (sorted(got), sorted(nm(k.lower()))))
elif part == "obs-trusted":
    # why `mokutil --import` skips the OBS certificate: the kernel already trusts it (/proc/keys) and so does db
    ski = ssl("-ext", "subjectKeyIdentifier").split("\n")[-1].strip().replace(":", "").lower()
    keys = rd("kernel-keys.out")
    kl = [l for l in keys.splitlines() if "asymmetri" in l and "home:i-danos OBS Project" in l]
    print("expected subjectKeyIdentifier=%s" % ski)
    for l in kl:
        print("/proc/keys: " + " ".join(l.split()))
    check("in-kernel-keys", any(ski in l.lower() for l in kl))
    db = rd("db.out")
    dfps = [x.lower() for x in re.findall(r"SHA1 Fingerprint: ([0-9a-fA-F:]{59})", db)]
    print("db sha1 list: %s" % (",".join(dfps) or "none"))
    check("in-db", sha1 in dfps)
elif part == "enrolled":
    e = rd("enrolled-after.out")
    fps = [x.lower() for x in re.findall(r"SHA1 Fingerprint: ([0-9a-fA-F:]{59})", e)]
    subj = re.findall(r"Subject: (.*)", e)
    print("enrolled sha1 list: %s" % (",".join(fps) or "none"))
    print("enrolled subjects: %s" % ("; ".join(s.strip() for s in subj) or "none"))
    check("key-enrolled", sha1 in fps)
    check("debian-secure-boot-ca-alongside", any("Debian Secure Boot CA" in s for s in subj))
sys.exit(0 if ok else 1)
