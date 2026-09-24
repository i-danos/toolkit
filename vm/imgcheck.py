#!/usr/bin/env python3
"""Runs ON an installed DANOS box, as root. Are the images on disk what the
boot menu says they are?

Usage: imgcheck.py <name>=<size>[:<sha256-prefix>] ...
       imgcheck.py <size> [<sha256-prefix>]        (one expectation for every image)

One line of key=value facts on stdout. The question is not "is there an image"
but "does every image grub can boot actually exist in full": the shared
grub.cfg is what the next boot obeys, so an entry pointing at a directory that
is missing its squashfs or holds a truncated one is a machine that will not
come back. An image directory grub does NOT mention is reported as an orphan,
not as a fault -- it is dead weight, not a boot hazard.

Complete means: the squashfs has exactly the expected size (and hash, when
given), the kernel and initrd are non-empty. The expected values come from a
control run of the same operation with no interruption.
"""
import glob
import hashlib
import os
import re
import sys

# Two images built from different ISOs have different squashfs files, so the
# expectation is per image. An image with no expectation is only required to
# have a squashfs and kernel that are not empty.
expect = {}
default = None
if sys.argv[1].isdigit():
    default = (int(sys.argv[1]), sys.argv[2] if len(sys.argv) > 2 else None)
else:
    for a in sys.argv[1:]:
        n, _, v = a.partition("=")
        sz, _, sha = v.partition(":")
        expect[n] = (int(sz), sha or None)

root = None
for c in glob.glob("/run/live/persistence/*"):
    if os.path.exists(c + "/boot/grub/grub.cfg"):
        root = c
        break
if root is None:
    print("error=no-grub-cfg")
    sys.exit(0)

cfg = open(root + "/boot/grub/grub.cfg", errors="replace").read()

# Image names grub would load: /boot/<name>/vmlinuz on a "linux" line.
refs = []
for m in re.finditer(r"^\s*linux\s+/boot/([^/\s]+)/vmlinuz", cfg, re.M):
    if m.group(1) not in refs:
        refs.append(m.group(1))

entries = re.findall(r"^menuentry\s+\"([^\"]*)\"", cfg, re.M)
entry_images = []
for m in re.finditer(r"^menuentry\s+\"[^\"]*\"[^{]*\{(.*?)^\}", cfg, re.M | re.S):
    l = re.search(r"^\s*linux\s+/boot/([^/\s]+)/vmlinuz", m.group(1), re.M)
    entry_images.append(l.group(1) if l else None)

d = re.search(r"^set default=(\d+)", cfg, re.M)
default_idx = int(d.group(1)) if d else 0
default_image = entry_images[default_idx] if default_idx < len(entry_images) else None


def complete(name):
    b = "%s/boot/%s" % (root, name)
    sq = "%s/%s.squashfs" % (b, name)
    exp_size, exp_sha = expect.get(name, default) or (None, None)
    try:
        if exp_size is not None and os.path.getsize(sq) != exp_size:
            return "squashfs-size-%d" % os.path.getsize(sq)
        if exp_size is None and os.path.getsize(sq) == 0:
            return "squashfs-empty"
        for k in ("vmlinuz", "initrd.img"):
            if os.path.getsize("%s/%s" % (b, k)) == 0:
                return "%s-empty" % k
    except OSError as e:
        return "missing-%s" % os.path.basename(e.filename or "?")
    if exp_sha:
        h = hashlib.sha256()
        with open(sq, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 22), b""):
                h.update(chunk)
        if not h.hexdigest().startswith(exp_sha):
            return "squashfs-hash-differs"
    return "ok"


state = {n: complete(n) for n in refs}
dirs = [x for x in os.listdir(root + "/boot") if x != "grub" and os.path.isdir(root + "/boot/" + x)]
orphans = [x for x in dirs if x not in refs]

cmd = open("/proc/cmdline").read()
r = re.search(r"vyatta-union=/boot/([^/\s]+)", cmd)
running = r.group(1) if r else "?"

print("running=%s refs=%s default=%s default_state=%s state=%s orphans=%s" % (
    running, ",".join(refs), default_image,
    state.get(default_image, "not-referenced"),
    ",".join("%s:%s" % (k, v) for k, v in state.items()),
    ",".join(orphans) or "-"))
