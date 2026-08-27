#!/usr/bin/env python3
"""Pre-build checks for the DANOS ISO.

Two checks, both of which fail deep inside `lb build` if skipped, with error
messages that point somewhere other than the real cause:

  1. package-list existence -- every package named in
     build-iso/config/package-lists/*.list.chroot must exist in one of the
     apt sources. A missing one surfaces as "Unable to locate package" tens of
     minutes into the build.

  2. dependency closure -- every Depends/Pre-Depends of every DANOS package in
     obs-repo must be satisfiable, either from obs-repo itself or from Debian
     trixie. An unsatisfiable one surfaces as a dpkg configure failure even
     later.

Usage: preflight.py [--repo DIR] [--lists DIR]
"""

import argparse
import gzip
import os
import re
import subprocess
import sys
import urllib.request
from collections import defaultdict

# Defaults for this working directory; override with --repo/--lists or by
# exporting OBS_REPO / PKG_LISTS.
REPO = os.environ.get("OBS_REPO", "/home/aikon/danos/build-iso/danos-build/obs-repo")
LISTS = os.environ.get("PKG_LISTS", "/home/aikon/danos/build-iso/danos-sources/build-iso/config/package-lists")
# The chroot's apt sources; see build-iso/config/apt/sources.list.
DEBIAN = [
    "https://mirrors.aliyun.com/debian/dists/trixie/main/binary-amd64/Packages.gz",
    "https://mirrors.aliyun.com/debian/dists/trixie/contrib/binary-amd64/Packages.gz",
    "https://mirrors.aliyun.com/debian/dists/trixie/non-free-firmware/binary-amd64/Packages.gz",
    "https://mirrors.aliyun.com/debian-security/dists/trixie-security/main/binary-amd64/Packages.gz",
    "https://mirrors.aliyun.com/debian/dists/trixie-updates/main/binary-amd64/Packages.gz",
]


def parse_packages(text):
    """Yield one dict per stanza of a Packages file."""
    for stanza in text.split("\n\n"):
        if not stanza.strip():
            continue
        fields, key = {}, None
        for line in stanza.split("\n"):
            if line[:1] in (" ", "\t") and key:
                fields[key] += " " + line.strip()
            elif ":" in line:
                key, _, val = line.partition(":")
                fields[key] = val.strip()
        if "Package" in fields:
            yield fields


def provides_index(stanzas):
    """package name -> set of names it satisfies (itself plus its Provides)."""
    have = set()
    for s in stanzas:
        have.add(s["Package"])
        for p in re.split(r",\s*", s.get("Provides", "")):
            p = p.split("(")[0].strip()
            if p:
                have.add(p)
    return have


def dep_names(field):
    """Flatten a Depends field to the set of alternatives in each clause.

    Strips version constraints "(>= 1.2)", architecture restrictions "[amd64]",
    build profiles "<!nocheck>", and the architecture qualifier in "perl:any" —
    that qualifier says which architecture may satisfy the dependency, not a
    different package name, and perl:any is satisfied by perl.

    Only a known architecture qualifier is stripped, never any colon: DANOS'
    protobuf feature packages carry a colon inside the name itself, as in
    "vyatta-dataplane-cfg-pb-vyatta:tcp-mss-0", and cutting at the first colon
    turns those into a name nothing provides.
    """
    for clause in re.split(r",\s*", field or ""):
        alts = set()
        for alt in clause.split("|"):
            name = alt.split("(")[0].split("[")[0].split("<")[0].strip()
            name = re.sub(r":(any|native|all|amd64|i386|arm64|armhf)$", "", name)
            if name:
                alts.add(name)
        if alts:
            yield alts


def local_packages(repo):
    """Build a Packages index from the .deb files in repo, via dpkg-deb."""
    debs = [f for f in os.listdir(repo) if f.endswith(".deb")]
    out = []
    for d in debs:
        try:
            ctrl = subprocess.run(
                ["dpkg-deb", "-f", os.path.join(repo, d)],
                capture_output=True, text=True, timeout=30,
            ).stdout
        except (subprocess.SubprocessError, OSError):
            continue
        if ctrl.strip():
            out.append(ctrl.strip())
    return list(parse_packages("\n\n".join(out)))


def fetch_debian():
    stanzas = []
    for url in DEBIAN:
        try:
            with urllib.request.urlopen(url, timeout=120) as r:
                stanzas += list(parse_packages(gzip.decompress(r.read()).decode("utf-8", "replace")))
        except Exception as e:                      # noqa: BLE001 - report and continue
            print(f"  WARN  cannot fetch {url}: {e}", file=sys.stderr)
    return stanzas


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=REPO)
    ap.add_argument("--lists", default=LISTS)
    args = ap.parse_args()

    print(f"local repo: {args.repo}")
    local = local_packages(args.repo)
    print(f"  {len(local)} binary packages")
    print("fetching Debian trixie indices ...")
    debian = fetch_debian()
    print(f"  {len(debian)} Debian packages")

    have = provides_index(local) | provides_index(debian)
    print()

    # ---- check 1: every package named in the lists exists -------------------
    print("== 1. package-list existence ==")
    requested, missing = [], []
    for fn in sorted(os.listdir(args.lists)):
        if not fn.endswith(".list.chroot"):
            continue
        for line in open(os.path.join(args.lists, fn), encoding="utf-8"):
            name = line.split("#")[0].strip()
            if not name:
                continue
            requested.append((fn, name))
            if name not in have:
                missing.append((fn, name))
    print(f"  {len(requested)} packages requested across the lists")
    if missing:
        for fn, name in missing:
            print(f"  MISSING  {name}   ({fn})")
    print(f"  missing total: {len(missing)}")
    print()

    # ---- check 2: dependency closure over what actually gets installed -----
    #
    # Scoped to the transitive closure of the package lists, not to every
    # package in obs-repo. Roughly 400 of the 823 built packages are never
    # installed -- debug metapackages referring to hardware-vendor dbgsyms,
    # superseded *-yang names, stale compiler shims -- and several of those do
    # have unsatisfiable dependencies. apt never looks at them, so reporting
    # them makes the check cry wolf and teaches you to ignore it.
    print("== 2. dependency closure (packages that actually get installed) ==")
    by_name = {}
    for s in local + debian:
        by_name.setdefault(s["Package"], s)
        for p in re.split(r",\s*", s.get("Provides", "")):
            p = p.split("(")[0].strip()
            if p:
                by_name.setdefault(p, s)

    seen, queue = set(), [n for _, n in requested]
    unmet = defaultdict(list)
    while queue:
        name = queue.pop()
        if name in seen:
            continue
        seen.add(name)
        s = by_name.get(name)
        if s is None:
            continue
        field = ", ".join(x for x in (s.get("Pre-Depends"), s.get("Depends")) if x)
        for alts in dep_names(field):
            if alts & have:
                for a in alts:
                    if a in by_name and a not in seen:
                        queue.append(a)
            else:
                unmet[s["Package"]].append(" | ".join(sorted(alts)))
    print(f"  closure: {len(seen)} packages reachable from the lists")
    if unmet:
        for pkg in sorted(unmet):
            print(f"  {pkg}")
            for d in unmet[pkg]:
                print(f"      needs {d}")
    print(f"  packages with unsatisfiable dependencies: {len(unmet)}")
    print()

    bad = len(missing) + len(unmet)
    print("PREFLIGHT OK" if bad == 0 else f"PREFLIGHT FAILED ({bad} problems)")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
