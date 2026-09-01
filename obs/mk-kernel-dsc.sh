#!/bin/bash
# Build the kernel source package on its own.
#
# The kernel cannot go through mk-dsc.sh's generic path, for two reasons:
#
# 1) HEAD's debian/ is broken for 6.12 — series still lists patches the tree
#    already contains, so it cannot even produce a source package. The working
#    version lives in the working tree (8 uncommitted files: the 6.12.101
#    version in the changelog, six #SKIP-ALREADY-APPLIED# markers in series,
#    rules.real installing scripts/module.lds, and four rules.d/ kbuild
#    adaptations).
#
# 2) The patches apply with offsets (version.patch's hunks land at offset 1 and
#    offset 4). debian/rules runs dpkg-source -b . again during the build, and
#    on that second comparison reads the offsets as upstream changes no patch
#    accounts for:
#      dpkg-source: error: aborting due to unexpected upstream changes
#    So each patch is pushed and refreshed with quilt to land exactly, before
#    the package is built.

set -u
# OBS_DIR is where the operational state lives -- dsc/ (generated source
# packages), the osc wrapper, run/ (console sockets), fixes/. It is deliberately
# separate from this toolkit: the scripts are worth keeping in version control,
# 2 GB of build output is not. Override it if your working directory differs.
OBS=${OBS_DIR:-/home/aikon/danos/.obs}
SRC=/home/aikon/danos/build-iso/danos-sources/linux-vyatta
STAGE=$OBS/stage/kern
OUT=$OBS/dsc
QUILT=$OBS/opt/usr/bin/quilt

VER=$(head -1 "$SRC/debian/changelog" | sed -n 's/.*(\([^)]*\)).*/\1/p')
UP=${VER%-*}
WORK="$STAGE/linux-$UP"

echo "version $VER, upstream $UP"
rm -rf "$STAGE"; mkdir -p "$WORK"

echo "== 1. export the HEAD source tree =="
git -C "$SRC" archive HEAD | tar -x -C "$WORK"
rm -rf "$WORK/debian"

echo "== 2. overlay the working tree's debian/ (excluding build leftovers) =="
rsync -a --exclude='build/' --exclude='stamps/' --exclude='tmp/' --exclude='__pycache__/' \
      --exclude='*.pyc' --exclude='*.substvars' --exclude='files' --exclude='.debhelper/' \
      --exclude='control.orig' \
      "$SRC/debian/" "$WORK/debian/"
mapfile -t bins < <(sed -n 's/^Package:[[:space:]]*//p' "$WORK/debian/control" | tr -d '\r')
for b in "${bins[@]}"; do [ -n "$b" ] && rm -rf "$WORK/debian/$b"; done
find "$WORK/debian" -mindepth 2 -maxdepth 2 -type d -name DEBIAN \
     -exec sh -c 'rm -rf "$(dirname "$1")"' _ {} \; 2>/dev/null

echo "== 2b. declare the pkg-config the perf build needs =="
# perf's Makefile.config requires pkg-config outright:
#   Makefile.config:198: *** Error: pkg-config needed by libtraceevent is missing
#     on this system, please install it.  Stop.
# In this repository's debian/control, however, pkg-config appears only in
# Testsuite-Triggers and is declared in neither Build-Depends nor
# Build-Depends-Arch. Debian's own linux source package does declare it
# (pkg-config <!stage1 !pkg.linux.notools>); this fork's control is an older
# version.
#
# The local build gets away with it thanks to the cumulative chroot once more:
# some other package pulled pkg-config in. The image does install
# linux-perf-6.12, so pkg.linux.notools is not a way around it.
if ! grep -q 'pkg-config <!stage1 !pkg.linux.notools>' "$WORK/debian/control"; then
  sed -i 's/libelf-dev <!stage1 !pkg\.linux\.notools>, /libelf-dev <!stage1 !pkg.linux.notools>, pkg-config <!stage1 !pkg.linux.notools>, libtraceevent-dev (>= 1:1.5) [amd64] <!stage1 !pkg.linux.notools>, libtracefs-dev (>= 1.3) [amd64] <!stage1 !pkg.linux.notools>, /' \
      "$WORK/debian/control"
  grep -q 'pkg-config <!stage1 !pkg.linux.notools>' "$WORK/debian/control" \
    && echo "  added to Build-Depends-Arch" || echo "  warning: insert failed, anchor did not match"
fi

echo "== 3. drop the #SKIP-ALREADY-APPLIED# markers =="
# The working tree's series marks six patches as already applied, but checking
# them one by one shows that *none* of them actually was — every one applies
# forward to a clean HEAD export:
#
#   arch-powerpc-platforms-8xx-ucode-disable.patch
#   drivers-media-dvb-dvb-usb-af9005-disable.patch
#   video-remove-nvidiafb-and-rivafb.patch
#   add-sysctl-to-disallow-unprivileged-CLONE_NEWUSER-by-default.patch
#   security-perf-allow-further-restriction-of-perf_event_open.patch
#   kbuild-fix-recordmcount-dependency.patch
#
# The markers were presumably tried against the stateful local working tree,
# which already has 2172 patches applied; in that context patch reports "already
# applied" and the patch got marked SKIP. Against a clean source tree the
# markers are simply wrong, and they do two kinds of damage:
#
#  1) They break a patch pair. dfsg's af9005-disable adds `depends on BROKEN`;
#     features' af9005-request_firmware removes it again and switches to
#     select FW_LOADER. Skip the first and the second finds no line to remove,
#     and the whole series stops there.
#  2) They silently drop two Debian hardening patches — disabling unprivileged
#     user namespaces by default, and restricting perf_event_open. The kernel in
#     the current ISO was built exactly that way.
#
# With the markers gone, all 26 patches apply cleanly.
n_skip=$(grep -c 'SKIP-ALREADY-APPLIED' "$WORK/debian/patches/series" || true)
sed -i 's/^#SKIP-ALREADY-APPLIED#//' "$WORK/debian/patches/series"
echo "  $n_skip mismarked patches restored, $(grep -vcE '^\s*(#|$)' "$WORK/debian/patches/series") active in series"

echo "== 3b. push and refresh one by one, to clear the offsets =="
cd "$WORK"
# quilt was unpacked from its .deb into a non-standard path, and it locates its
# own subcommand scripts by absolute path (: ${QUILT_DIR=/usr/share/quilt}).
# Without that variable set, every subcommand just prints the global usage.
export QUILT_DIR="$OBS/opt/usr/share/quilt"
export QUILT_PATCHES=debian/patches
export QUILT_REFRESH_ARGS="-p ab --no-timestamps --no-index"

n=0
while :; do
  nxt=$("$QUILT" next 2>/dev/null) || break
  [ -n "$nxt" ] || break
  if "$QUILT" push -q --refresh >/dev/null 2>&1; then
    n=$((n+1)); echo "  refresh $nxt"
  else
    echo "  push failed, stopped at: $nxt"
    "$QUILT" push 2>&1 | grep -iE 'error|hunk|fail|reject' | head -4 | sed 's/^/      /'
    break
  fi
done
echo "  $n refreshed in total"

echo "== 4. pop everything, back to a clean upstream tree =="
"$QUILT" pop -a -q >/dev/null 2>&1
rm -rf "$WORK/.pc"

echo "== 4b. replay patches-vyatta at fuzz 0, the way debian/rules.real does =="
# Step 3b refreshes debian/patches only. patches-vyatta is copied over verbatim
# and is applied much later, by debian/rules.real during binary-indep, with
# quilt --fuzz=0. A stable import that shifts context near one of those patches
# therefore produces a source package that looks fine here and dies halfway
# through the build on OBS -- taking bvnos-linux-libc-dev with it, which leaves
# six dependent packages unresolvable. Catch it before the upload.
if ! "$SRC/../toolkit/build/96-check_kernel_patches.sh" "$WORK"; then
  echo "aborting: patches-vyatta would fail on the build host" >&2
  exit 1
fi

echo "== 5. build the orig (xz; gz would be 250 MB and gets cut off by an SSL EOF) =="
rm -f "$OUT/linux_$UP.orig.tar."* "$OUT/linux_$VER.dsc" "$OUT/linux_$VER.debian.tar."*
tar -cf - -C "$STAGE" --exclude="linux-$UP/debian" "linux-$UP" | xz -T1 -6 > "$OUT/linux_$UP.orig.tar.xz"
ls -la "$OUT/linux_$UP.orig.tar.xz"

echo "== 6. dpkg-source -b =="
(cd "$OUT" && dpkg-source --no-check -b "$WORK" 2>&1 | grep -iE 'error|warning' | head -5)
ls -la "$OUT"/linux_* 2>/dev/null
