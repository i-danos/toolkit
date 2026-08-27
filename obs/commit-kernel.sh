#!/bin/bash
# Commit the whole kernel change set into linux-vyatta.
#
# Four things have to land together (see fixes/linux-vyatta/README.md):
#   1) Eight uncommitted files in the working tree — 6.12.101 in the changelog,
#      series, rules.real installing scripts/module.lds, and four rules.d kbuild
#      adaptations. HEAD alone cannot even produce a source package.
#   2) All six #SKIP-ALREADY-APPLIED# markers in series are wrong: every one of
#      those patches applies forward to a clean tree, and the markers silently
#      dropped two Debian hardening patches.
#   3) The patches need refreshing. They apply with offsets, and when
#      debian/rules runs dpkg-source -b during the build it reads those offsets
#      as upstream changes no patch accounts for.
#   4) Build-Depends-Arch is missing pkg-config, libtraceevent-dev and
#      libtracefs-dev, plus the new asciidoctor patch for the perf docs.
#
# Refreshing has to happen on a clean tree (the working tree already has 2172
# patches applied), so: export HEAD, lay the working tree's debian/ over it,
# refresh there, then copy the result back into the repository.

set -eu
# OBS_DIR is where the operational state lives -- dsc/ (generated source
# packages), the osc wrapper, run/ (console sockets), fixes/. It is deliberately
# separate from this toolkit: the scripts are worth keeping in version control,
# 2 GB of build output is not. Override it if your working directory differs.
OBS=${OBS_DIR:-${OBS_DIR:-/home/aikon/danos/.obs}}
R=/home/aikon/danos/build-iso/danos-sources/linux-vyatta
W=$(mktemp -d /tmp/kcommit.XXXXXX)
QUILT="$OBS/opt/usr/bin/quilt"
trap 'rm -rf "$W"' EXIT

VER=$(head -1 "$R/debian/changelog" | sed -n 's/.*(\([^)]*\)).*/\1/p')
UP=${VER%-*}
T="$W/linux-$UP"

echo "== 1. export the HEAD source tree =="
mkdir -p "$T"
git -C "$R" archive HEAD | tar -x -C "$T"
rm -rf "$T/debian"

echo "== 2. overlay the working tree's debian/ (excluding build leftovers) =="
rsync -a --exclude='build/' --exclude='stamps/' --exclude='tmp/' --exclude='__pycache__/' \
      --exclude='*.pyc' --exclude='*.substvars' --exclude='files' --exclude='.debhelper/' \
      --exclude='control.orig' \
      "$R/debian/" "$T/debian/"
mapfile -t bins < <(sed -n 's/^Package:[[:space:]]*//p' "$T/debian/control" | tr -d '\r')
for b in "${bins[@]}"; do [ -n "$b" ] && rm -rf "$T/debian/$b"; done
find "$T/debian" -mindepth 2 -maxdepth 2 -type d -name DEBIAN \
     -exec sh -c 'rm -rf "$(dirname "$1")"' _ {} \; 2>/dev/null || true

echo "== 3. declare perf's Build-Depends =="
if ! grep -q 'pkg-config <!stage1 !pkg.linux.notools>' "$T/debian/control"; then
  sed -i 's/libelf-dev <!stage1 !pkg\.linux\.notools>, /libelf-dev <!stage1 !pkg.linux.notools>, pkg-config <!stage1 !pkg.linux.notools>, libtraceevent-dev (>= 1:1.5) [amd64] <!stage1 !pkg.linux.notools>, libtracefs-dev (>= 1.3) [amd64] <!stage1 !pkg.linux.notools>, /' \
      "$T/debian/control"
  grep -q 'libtracefs-dev' "$T/debian/control" || { echo "insert failed" >&2; exit 1; }
fi

echo "== 4. drop the six mistaken SKIP markers =="
n=$(grep -c 'SKIP-ALREADY-APPLIED' "$T/debian/patches/series" || true)
sed -i 's/^#SKIP-ALREADY-APPLIED#//' "$T/debian/patches/series"
echo "   $n restored"

echo "== 5. add the perf documentation asciidoctor patch =="
PF=perf-doc-asciidoctor-no-asciidoc-flags.patch
if ! grep -q "$PF" "$T/debian/patches/series"; then
  cp "$OBS/fixes/linux-vyatta/patches/$PF" "$T/debian/patches/$PF"
  echo "$PF" >> "$T/debian/patches/series"
fi

echo "== 6. push --refresh one by one to clear offsets, then pop =="
cd "$T"
export QUILT_DIR="$OBS/opt/usr/share/quilt" QUILT_PATCHES=debian/patches
export QUILT_REFRESH_ARGS="-p ab --no-timestamps --no-index"
c=0
while :; do
  nxt=$("$QUILT" next 2>/dev/null) || break
  [ -n "$nxt" ] || break
  "$QUILT" push -q --refresh >/dev/null 2>&1 || { echo "   push failed at $nxt" >&2; exit 1; }
  c=$((c+1))
done
echo "   $c refreshed"
"$QUILT" pop -a -q >/dev/null 2>&1 || true
rm -rf "$T/.pc"

echo "== 7. copy back into the repository =="
rsync -a --delete "$T/debian/patches/" "$R/debian/patches/"
cp "$T/debian/control" "$R/debian/control"
echo "   debian/patches/ and debian/control updated"

echo "== 8. commit =="
cd "$R"
git add debian/changelog debian/control debian/patches \
        debian/rules.real debian/rules.d
git commit --quiet -F - <<'MSG'
Commit the 6.12 port: version, patch series, kbuild adaptations

The tree shipped 6.12.101-1vyatta1 while HEAD still said 6.12.94-1vyatta1;
everything that made 6.12 build lived only in the working tree. Only debian/
changes are here — the applied quilt patches and build residue stay untracked
as before.

debian/patches/series: drop six #SKIP-ALREADY-APPLIED# markers. Each of those
patches applies cleanly to a clean export, so none of them had actually been
applied. The markers were presumably tried against the stateful working tree,
where patch reports "already applied". They did two kinds of damage:

  - They broke a patch pair. debian/dfsg/af9005-disable adds "depends on
    BROKEN"; features/all/af9005-request_firmware removes it again and adds
    select FW_LOADER. Skipping the first left the second with nothing to
    remove and the series stopped there.

  - They silently dropped two Debian hardening patches:
    add-sysctl-to-disallow-unprivileged-CLONE_NEWUSER-by-default and
    security-perf-allow-further-restriction-of-perf_event_open. The kernel in
    the current ISO was built without them.

All 26 patches are refreshed so they apply at fuzz 0. Without that,
debian/rules' own "dpkg-source -b ." during the build reads the offsets as
unrecorded upstream changes and aborts.

debian/control: declare pkg-config, libtraceevent-dev (>= 1:1.5) and
libtracefs-dev (>= 1.3) for the perf build. pkg-config appeared only in
Testsuite-Triggers; the other two are what Debian's own linux 6.12.86-1
declares. libtraceevent moved out of the kernel tree in 6.12.

New patch perf-doc-asciidoctor-no-asciidoc-flags: perf's Documentation
Makefile sets the asciidoc-only flags unconditionally and with +=, so
USE_ASCIIDOCTOR=1 switches the binary but leaves --unsafe -f asciidoc.conf in
place, which asciidoctor 2.0.23 rejects.

debian/rules.real installs scripts/module.lds, which newer kbuild needs for
external module builds; the rules.d changes adapt the rest to it.
MSG
git log -1 --format='   %h %an | %s'
echo
echo "Done. Verify:"
git status --porcelain debian/ | grep -vE '\.pc/|debian/build/|debian/stamps/|debian/linux-|debian/tmp|__pycache__' | head -5
echo "   (empty above means no substantive uncommitted changes remain under debian/)"
