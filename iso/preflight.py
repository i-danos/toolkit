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
import lzma
from email.utils import parsedate_to_datetime
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
# The mirror the chroot installs from. Must match build-iso/auto/config, or
# this checks a different archive from the one the build will use.
MIRROR = os.environ.get("DEBIAN_MIRROR", "https://mirrors.tuna.tsinghua.edu.cn")

# The chroot's apt sources; see build-iso/config/apt/sources.list. Packages.xz
# rather than .gz: several mirrors publish only the xz form, and asking for a
# .gz that is not there produced a warning on every run that was true, ignored,
# and unrelated to the failure it was eventually blamed for.
DEBIAN = [
    MIRROR + "/debian/dists/trixie/main/binary-amd64/Packages.xz",
    MIRROR + "/debian/dists/trixie/contrib/binary-amd64/Packages.xz",
    MIRROR + "/debian/dists/trixie/non-free-firmware/binary-amd64/Packages.xz",
    MIRROR + "/debian-security/dists/trixie-security/main/binary-amd64/Packages.xz",
    MIRROR + "/debian/dists/trixie-updates/main/binary-amd64/Packages.xz",
]

# How far behind deb.debian.org the mirror may be before it is a problem. A
# mirror is a cache and owes nobody freshness; this build installs OBS packages
# built against current Debian beside Debian packages from here, so a stale one
# breaks them against each other. Aliyun sat two months behind and served
# perl 5.40.1-6 while trixie/main had moved to 5.40.1-6+deb13u1, and apt
# reported held broken packages naming perl -- nothing named the mirror.
MIRROR_MAX_LAG_DAYS = 3


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
    failed = []
    for url in DEBIAN:
        try:
            with urllib.request.urlopen(url, timeout=180) as r:
                raw = r.read()
            text = (lzma.decompress(raw) if url.endswith(".xz")
                    else gzip.decompress(raw)).decode("utf-8", "replace")
            stanzas += list(parse_packages(text))
        except Exception as e:                      # noqa: BLE001 - report and continue
            failed.append(f"{url}: {e}")
    # An index that cannot be read is a hole in the closure check below, and a
    # hole makes it pass for the wrong reason: nothing can be unsatisfiable
    # against packages nobody managed to list. These used to be warnings on
    # every run, which is how two of them came to be scrolled past for weeks.
    if failed:
        print("  could not read %d of %d indices:" % (len(failed), len(DEBIAN)))
        for f in failed:
            print("    " + f)
        print("  The dependency closure below would pass by omission, so it is")
        print("  not run.")
        sys.exit(1)
    return stanzas


def mirror_lag_days():
    """How far the chroot mirror's trixie trails deb.debian.org's, in days.

    Returns None if either Release is unreadable, which is reported rather
    than treated as fresh.
    """
    def release_date(base):
        url = base + "/debian/dists/trixie/Release"
        with urllib.request.urlopen(url, timeout=60) as r:
            for line in r.read().decode("utf-8", "replace").splitlines():
                if line.startswith("Date:"):
                    return parsedate_to_datetime(line[5:].strip())
        return None

    try:
        ours = release_date(MIRROR)
        theirs = release_date("https://deb.debian.org")
    except Exception:                               # noqa: BLE001
        return None
    if ours is None or theirs is None:
        return None
    return (theirs - ours).total_seconds() / 86400.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=REPO)
    ap.add_argument("--lists", default=LISTS)
    args = ap.parse_args()

    print(f"local repo: {args.repo}")
    local = local_packages(args.repo)
    print(f"  {len(local)} binary packages")
    print(f"chroot mirror: {MIRROR}")
    lag = mirror_lag_days()
    if lag is None:
        print("  WARN  could not compare its trixie against deb.debian.org")
    elif lag > MIRROR_MAX_LAG_DAYS:
        print(f"  {lag:.0f} days behind deb.debian.org -- too stale to build against.")
        print("  OBS builds against current Debian, so its packages will depend on")
        print("  versions this mirror does not carry, and apt will report held")
        print("  broken packages naming a library rather than the mirror.")
        sys.exit(1)
    else:
        print(f"  {lag:.1f} days behind deb.debian.org")
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
