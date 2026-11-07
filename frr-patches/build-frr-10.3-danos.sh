#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build Debian's frr 10.3-3+deb13u1 with the DANOS nexthop-group patch, as 10.3-3+deb13u1danos1. Runs INSIDE a debian:13-slim container.
#
# Unlike build-frr-10.3-patched.sh (which patches the unpacked tree with patch -p1), this adds the patch to debian/patches/ and its series
# file, so the result is a real quilt source package (frr_10.3-3+deb13u1danos1.dsc is produced next to the binaries) and the patch is
# applied by dpkg-source, the same way Debian's own patches are. Build-Depends are installed with mk-build-deps from Debian only.
#
# Mounts:  /in   frr_10.3-3+deb13u1.dsc, .debian.tar.xz, frr_10.3.orig.tar.xz  (the pristine Debian source, checksums verified by the caller)
#          /patch  the patch file (0001-zebra-nhg-...-10.3.patch)
#          env SRC_ONLY=1 produces only the source package (frr_<ver>.dsc + .debian.tar.xz); the original is the pristine Debian orig tarball
#          env DEBIAN_MIRROR / DEBIAN_SECURITY_MIRROR (optional, as in build-iso-container.sh)
#          /out    receives the .debs, the source package, build.log and a SHA256SUMS
# Start it through toolkit/build/docker-run-doh.sh when the host's DNS is broken:
#   docker-run-doh.sh -- --rm -v IN:/in:ro -v PATCH:/patch:ro -v OUT:/out -v $PWD/build-frr-10.3-danos.sh:/build.sh:ro debian:13-slim bash /build.sh
set -u
export DEBIAN_FRONTEND=noninteractive
VER=10.3-3+deb13u1danos1
PATCHNAME=danos-zebra-nhg-do-not-reuse-old-nhe-with-inactive-member.patch
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
fail() { log "FATAL $*"; exit 1; }

{
	echo 'Acquire::Retries "8";'
	echo 'Acquire::ForceIPv4 "true";'
} > /etc/apt/apt.conf.d/80danos
# Same knobs as build-iso-container.sh: the CDN path from bench was measured at 118 kB/s on 2026-11-07, the Aliyun mirror is far faster.
if [ -n "${DEBIAN_MIRROR:-}" ]; then
	sed -i "s|http://deb.debian.org/debian-security|${DEBIAN_SECURITY_MIRROR:-${DEBIAN_MIRROR%/}-security}|; s|http://deb.debian.org/debian|${DEBIAN_MIRROR%/}|" /etc/apt/sources.list.d/debian.sources
	log "Debian mirror: $DEBIAN_MIRROR"
fi
log "apt update"; apt-get update -q >/out/apt.log 2>&1 || fail "apt-get update failed, see apt.log"
log "installing build tools"
apt-get install -y -q --no-install-recommends build-essential dpkg-dev devscripts equivs fakeroot ca-certificates patch >>/out/apt.log 2>&1 || fail "build tools"

mkdir -p /build && cd /build && rm -rf ./*
cp /in/frr_10.3* . || fail "no source in /in"
log "unpacking the pristine source (Debian's own patches are applied by dpkg-source)"
dpkg-source -x frr_10.3-3+deb13u1.dsc frr-10.3 >/out/unpack.log 2>&1 || fail "dpkg-source -x failed"
cd frr-10.3

log "adding the patch to debian/patches (quilt series)"
cp /patch/*.patch "debian/patches/$PATCHNAME"
# a quilt patch needs -p1 paths and a header; the file already has a/ b/ paths
tail -c1 debian/patches/series | od -An -c | grep -q '\\n' || echo >> debian/patches/series
echo "$PATCHNAME" >> debian/patches/series
log "dry run through dpkg-source's own mechanism: quilt is not installed, so use patch to prove it applies on top of the whole series"
patch -p1 --dry-run < "debian/patches/$PATCHNAME" >/out/patch-check.log 2>&1 || log "NOTE: patch --dry-run on the unpatched tree: $(tail -1 /out/patch-check.log) (expected only if Debian's series is not applied yet)"

log "changelog entry $VER"
dch --force-bad-version -v "$VER" -D unstable "zebra: do not reuse an old nexthop group that holds an inactive member (DANOS-Open 2608)." >/dev/null 2>&1 || fail "dch failed"
head -3 debian/changelog | tee /out/changelog-head.txt

log "source package (before the build, from the clean tree): frr_$VER.dsc"
( cd /build && dpkg-source -b frr-10.3 >/out/source-build.log 2>&1 ) || { tail -5 /out/source-build.log; fail "dpkg-source -b failed"; }
cp -v /build/frr_$VER.dsc /build/frr_$VER.debian.tar.xz /out/ | tail -2
if [ "${SRC_ONLY:-0}" = 1 ]; then ( cd /out && sha256sum frr_$VER.dsc frr_$VER.debian.tar.xz > SHA256SUMS-source ); chown -R "${HOST_UID:-1000}:${HOST_GID:-1000}" /out; log "done (source only)"; exit 0; fi

log "installing Build-Depends (mk-build-deps; apt output in apt.log)"
mk-build-deps -i -r -t "apt-get -y -q --no-install-recommends" debian/control >>/out/apt.log 2>&1 || fail "mk-build-deps failed, see apt.log"

log "building (nocheck): dpkg-buildpackage -us -uc -b, -j$(nproc)"
export DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)"
dpkg-buildpackage -us -uc -b -d -Pnocheck > /out/build.log 2>&1
rc=$?
log "dpkg-buildpackage rc=$rc"
[ $rc -eq 0 ] || { tail -25 /out/build.log; fail "build failed"; }
grep -E "applying $PATCHNAME|dpkg-source: info: applying" /out/build.log | tail -4 | tee /out/patch-applied-in-build.txt

cd /build
cp -v /build/*.deb /build/*.dsc /build/*.debian.tar.xz /build/*.buildinfo /build/*.changes /out/ 2>/dev/null | tail -12
( cd /out && sha256sum *.deb *.dsc *.debian.tar.xz 2>/dev/null > SHA256SUMS )
chown -R "${HOST_UID:-1000}:${HOST_GID:-1000}" /out 2>/dev/null
log "done"
