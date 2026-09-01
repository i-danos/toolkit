#!/bin/bash
# Assemble a local apt repository from the packages OBS built, for the ISO build.
#
# The point is closed-loop verification: every DANOS package in the image comes
# from OBS, and OBS in turn built from git HEAD.
#
# Five packages used to be absent from OBS and had to be taken from the old
# local repository. All five are now closed out, so EXTRA_LOCAL_PKGS is empty
# and everything here comes from OBS. See step 3 for what happened to each.
#
# The build configuration needs no change: config/archives/danos.list.chroot
# still points at http://127.0.0.1:8080/; only the directory it serves moves
# here.
#
# One trap worth stating explicitly: the build container uses bridge
# networking, so 127.0.0.1 inside it is the container, not this host. Serving
# this directory from the host leaves live-build fetching from whatever is
# already listening inside the container — which was the old local-repo. The
# HTTP server has to be started inside the container, on this directory.

set -u
# OBS_DIR is where the operational state lives -- dsc/ (generated source
# packages), the osc wrapper, run/ (console sockets), fixes/. It is deliberately
# separate from this toolkit: the scripts are worth keeping in version control,
# 2 GB of build output is not. Override it if your working directory differs.
OBS=${OBS_DIR:-${OBS_DIR:-/home/aikon/danos/.obs}}
OSC="$OBS/osc -A https://api.opensuse.org"
OLD=/home/aikon/danos/build-iso/danos-build/local-repo
NEW=/home/aikon/danos/build-iso/danos-build/obs-repo
PUB=/published/home:i-danos/2608

mkdir -p "$NEW"

echo "== 1. fetch the OBS Packages index =="
# The index is the authority for step 3b, which deletes everything not named in
# it. A truncated fetch is therefore destructive, and truncation is easy to hit:
# `> file` empties the target before osc writes a byte, so a timeout partway
# through leaves a short but well-formed index. That happened once -- a fetch cut
# off at 64 of 823 entries took 750 packages out of an assembled repository.
#
# A short index is well-formed, so it cannot be recognised from its own
# contents, and the exit status does not help either: OBS returns partial
# responses under load with osc still exiting 0 (seen at 64/823 and 467/823,
# minutes apart, while an unhurried fetch of the same index returns all 823).
#
# So do not trust one transport. Fetch the same index two independent ways --
# osc against the API, and plain https from the mirror network -- and use it
# only when they agree byte for byte. Both truncating identically is not
# something a busy server does. Then, as a second line, refuse a large shrink
# against the index kept from last time.
#
# No trap here: step 3b sets its own EXIT trap and would replace this one.
TMPIDX=$(mktemp)
TMPIDX2=$(mktemp)
DLIDX=https://download.opensuse.org/repositories/home:/i-danos/2608/Packages

agreed=""
for attempt in 1 2 3; do
	timeout 600 $OSC api "$PUB/Packages" < /dev/null 2>/dev/null > "$TMPIDX"
	timeout 600 curl -sSL --max-time 600 "$DLIDX" -o "$TMPIDX2" 2>/dev/null
	a=$(grep -c '^Package: ' "$TMPIDX")
	b=$(grep -c '^Package: ' "$TMPIDX2")
	if [ "$a" -gt 0 ] && cmp -s "$TMPIDX" "$TMPIDX2"; then
		agreed=yes
		break
	fi
	echo "   attempt $attempt: osc says $a, https says $b -- disagree, retrying" >&2
	sleep 10
done
if [ -z "$agreed" ]; then
	echo "   two transports never agreed on the index -- refusing to use it" >&2
	echo "   (the repository is left as it is; rerun when OBS settles)" >&2
	rm -f "$TMPIDX" "$TMPIDX2"
	exit 1
fi

total=$(grep -c '^Package: ' "$TMPIDX")
prev=$(grep -c '^Package: ' "$NEW/.Packages.src" 2>/dev/null || echo 0)
rm -f "$TMPIDX2"

if [ "$total" -lt 100 ]; then
	echo "   index has only $total entries -- refusing to use it" >&2
	echo "   (the repository is left as it is; rerun when OBS answers)" >&2
	rm -f "$TMPIDX"
	exit 1
fi
if [ "$prev" -gt 0 ] && [ "$total" -lt $((prev * 9 / 10)) ]; then
	echo "   index shrank $prev -> $total (>10%) -- refusing to use it" >&2
	echo "   if the shrink is real, delete $NEW/.Packages.src and rerun" >&2
	rm -f "$TMPIDX"
	exit 1
fi
cp "$TMPIDX" "$NEW/.Packages.src"
rm -f "$TMPIDX"
echo "   $total packages (was $prev)"

echo "== 2. download =="
# Filename carries a subdirectory prefix (amd64/xxx.deb, all/xxx.deb), so
# taking the basename is wrong — osc api would then hit the directory and
# return a 25-byte <directory></directory>. The public URL is also faster than
# osc api and follows redirects to a nearby mirror.
DL=https://download.opensuse.org/repositories/home:/i-danos/2608
export DL NEW

# Downloading serially takes about 23 seconds per package -- almost all of it
# round-trip latency to download.opensuse.org, not bandwidth. Over 823 packages
# that is five hours, and an interrupted run used to lose everything because
# this directory was emptied at the start.
#
# So: fetch in parallel, and skip anything already here that matches the index.
# A re-run after an interruption costs only what is missing. Staleness is handled
# at the end instead of by emptying the directory up front -- anything not named
# in the current index is removed there, which is the same guarantee without the
# cost.
#
# "Matches the index" means the SHA256 from the index, not `dpkg-deb -f`. A .deb
# is an ar archive holding control.tar then data.tar, so `dpkg-deb -f` reads only
# the first member and answers correctly for a file whose data.tar was cut off
# mid-transfer. Observed: vci-template-go arrived as 130684 of 1539088 bytes
# after an SSL "unexpected eof", and `dpkg-deb -f` still printed its name --
# a repository that passes its own validity check and installs nothing.
awk '/^Filename: /{f=$2} /^SHA256: /{s=$2}
     /^$/{if (f!="" && s!="") print f, s; f=""; s=""}
     END{if (f!="" && s!="") print f, s}' "$NEW/.Packages.src" \
  | xargs -P "${JOBS:-12}" -n2 sh -c '
      p=$1; want=$2; b=$(basename "$p")
      if [ -s "$NEW/$b" ] \
         && [ "$(sha256sum "$NEW/$b" | cut -d" " -f1)" = "$want" ]; then
        exit 0
      fi
      for try in 1 2 3; do
        if curl -sSL --max-time 300 -o "$NEW/$b" "$DL/$p" 2>/dev/null \
           && [ "$(sha256sum "$NEW/$b" | cut -d" " -f1)" = "$want" ]; then
          exit 0
        fi
        sleep 3
      done
      echo "   failed: $p" >&2; rm -f "$NEW/$b"' _

n=$(ls "$NEW"/*.deb 2>/dev/null | wc -l)
fail=$((total - n))
echo "   $n present, $fail missing"

echo "== 3b. drop packages no longer in the index =="
# Replaces the old "rm -rf at the start". Same staleness guarantee, but a
# re-run does not re-download everything that was already correct.
keep=$(mktemp); trap 'rm -f "$keep"' EXIT
grep -oP '^Filename: \K.*' "$NEW/.Packages.src" | xargs -n1 basename | sort > "$keep"
for f in "$NEW"/*.deb; do
  [ -e "$f" ] || continue
  b=$(basename "$f")
  grep -qxF "$b" "$keep" || { echo "   - $b"; rm -f "$f"; }
done

echo "== 3. supplement from the old local repository (nothing left to add) =="
# All five former gaps are closed, so EXTRA_LOCAL_PKGS is empty and this loop
# is a no-op. Kept so a future gap has somewhere to go.
#   cloud-init  -- the repository is complete and is now built on OBS
#                  (build_order.txt line 43's note did not match reality)
#   iproute     -- the three consumers now depend on iproute2; the stub is gone
#   watchdog x3 -- came from the abandoned vyatta-ipmi and are removed from the
#                  image's package lists
for p in "${EXTRA_LOCAL_PKGS[@]:-}"; do
  [ -n "$p" ] || continue
  for f in "$OLD/${p}_"*.deb; do
    [ -e "$f" ] || continue
    # Match the package name exactly, so cloud-init does not also catch
    # cloud-init-something
    [ "$(dpkg-deb -f "$f" Package 2>/dev/null)" = "$p" ] || continue
    cp "$f" "$NEW/" && printf '   + %s\n' "$(basename "$f")"
  done
done

echo "== 4. generate the index =="
# .Packages.src is deliberately kept: step 1 compares the next fetch against it
# to catch a truncated index before step 3b deletes anything. It is a dotfile,
# so dpkg-scanpackages and apt both ignore it.
cd "$NEW"
dpkg-scanpackages -m . /dev/null > Packages 2>/dev/null
gzip -9kf Packages
xz -9kf Packages
# apt-ftparchive comes from apt-utils unpacked without root. Release has to be
# generated by it: a hand-written one lacks the self-checksums and apt then
# reports "File has unexpected size".
LD_LIBRARY_PATH=$OBS/opt/usr/lib/x86_64-linux-gnu \
  $OBS/opt/usr/bin/apt-ftparchive \
    -o APT::FTPArchive::Release::Suite=danos \
    -o APT::FTPArchive::Release::Codename=trixie \
    release . > Release
echo "   $(grep -c '^Package: ' Packages) packages, $(du -sh . | cut -f1)"
