#!/bin/bash
# Reuse the orig already on OBS and regenerate only the .dsc and debian.tar.xz.
#
# Why this path exists: uploading the 147 MB orig fails reproducibly. Measured,
# it is cut off by "Connection reset by peer" at 85 MB / 231 s, averaging
# 367 KB/s — at that rate the full transfer would take about 420 s, so something
# in the middle severs it at roughly four minutes. The download direction is
# fine (153 MB in one go).
#
# The orig on OBS was generated from this same tree, but the inner tar's sha256
# differs from a locally regenerated one: quilt's push/refresh/pop rewrites file
# mtimes, so two runs carry different timestamps — identical content, different
# tar metadata. Regenerating byte-identical output is therefore not a way to
# skip the upload.
#
# So do it the other way round: unpack the OBS orig as the source tree, lay the
# fixed debian/ over it, and have dpkg-source generate the .dsc against it. The
# .dsc then records the OBS copy's checksums, and only the .dsc and
# debian.tar.xz need uploading — under 800 KB together.

set -u
# OBS_DIR is where the operational state lives -- dsc/ (generated source
# packages), the osc wrapper, run/ (console sockets), fixes/. It is deliberately
# separate from this toolkit: the scripts are worth keeping in version control,
# 2 GB of build output is not. Override it if your working directory differs.
OBS=${OBS_DIR:-${OBS_DIR:-/home/aikon/danos/.obs}}
SRC=/home/aikon/danos/build-iso/danos-sources/linux-vyatta
STAGE=$OBS/stage/kreuse
OUT=$OBS/dsc
ORIG=${1:?usage: mk-kernel-dsc-reuse.sh <orig.tar.xz downloaded from OBS>}

VER=$(head -1 "$SRC/debian/changelog" | sed -n 's/.*(\([^)]*\)).*/\1/p')
UP=${VER%-*}
WORK="$STAGE/linux-$UP"

echo "version $VER, reusing orig: $(basename "$ORIG") ($(du -h "$ORIG" | cut -f1))"
rm -rf "$STAGE"; mkdir -p "$STAGE"

echo "== 1. unpack the OBS orig as the source tree =="
tar -xJf "$ORIG" -C "$STAGE"
[ -d "$WORK" ] || { echo "unpacked directory is not linux-$UP" >&2; ls "$STAGE" >&2; exit 1; }

echo "== 2. overlay the working tree's debian/ =="
rsync -a --exclude='build/' --exclude='stamps/' --exclude='tmp/' --exclude='__pycache__/' \
      --exclude='*.pyc' --exclude='*.substvars' --exclude='files' --exclude='.debhelper/' \
      --exclude='control.orig' \
      "$SRC/debian/" "$WORK/debian/"
mapfile -t bins < <(sed -n 's/^Package:[[:space:]]*//p' "$WORK/debian/control" | tr -d '\r')
for b in "${bins[@]}"; do [ -n "$b" ] && rm -rf "$WORK/debian/$b"; done
find "$WORK/debian" -mindepth 2 -maxdepth 2 -type d -name DEBIAN \
     -exec sh -c 'rm -rf "$(dirname "$1")"' _ {} \; 2>/dev/null

echo "== 3. declare the Build-Depends the perf build needs (pkg-config, libtraceevent-dev, libtracefs-dev) =="
if ! grep -q 'pkg-config <!stage1 !pkg.linux.notools>' "$WORK/debian/control"; then
  sed -i 's/libelf-dev <!stage1 !pkg\.linux\.notools>, /libelf-dev <!stage1 !pkg.linux.notools>, pkg-config <!stage1 !pkg.linux.notools>, libtraceevent-dev (>= 1:1.5) [amd64] <!stage1 !pkg.linux.notools>, libtracefs-dev (>= 1.3) [amd64] <!stage1 !pkg.linux.notools>, /' \
      "$WORK/debian/control"
  grep -q 'pkg-config <!stage1 !pkg.linux.notools>' "$WORK/debian/control" \
    && echo "  added" || { echo "  insert failed, anchor did not match" >&2; exit 1; }
fi

echo "== 4. drop the #SKIP-ALREADY-APPLIED# markers =="
n_skip=$(grep -c 'SKIP-ALREADY-APPLIED' "$WORK/debian/patches/series" || true)
sed -i 's/^#SKIP-ALREADY-APPLIED#//' "$WORK/debian/patches/series"
echo "  $n_skip restored, $(grep -vcE '^\s*(#|$)' "$WORK/debian/patches/series") active in series"

echo "== 4b. add the perf documentation asciidoctor patch =="
# tools/perf/Documentation/Makefile sets the asciidoc(1) flags unconditionally
# and with +=:
#   ASCIIDOC=asciidoc
#   ASCIIDOC_EXTRA += --unsafe -f asciidoc.conf
# The ifdef USE_ASCIIDOCTOR block below only appends, never resets, so with
# USE_ASCIIDOCTOR=1 the executable becomes asciidoctor while the asciidoc-only
# flags remain, and asciidoctor 2.0.23 refuses:
#   asciidoctor: invalid option: --unsafe
# Every perf-*.1 target fails and takes build-perf down with it.
PF=perf-doc-asciidoctor-no-asciidoc-flags.patch
if ! grep -q "$PF" "$WORK/debian/patches/series"; then
  cp "$OBS/fixes/linux-vyatta/patches/$PF" "$WORK/debian/patches/$PF"
  echo "$PF" >> "$WORK/debian/patches/series"
  echo "  added to series ($(grep -vcE '^\s*(#|$)' "$WORK/debian/patches/series") now active)"
fi

echo "== 5. push --refresh then pop, to clear the offsets =="
cd "$WORK"
export QUILT_DIR="$OBS/opt/usr/share/quilt" QUILT_PATCHES=debian/patches
export QUILT_REFRESH_ARGS="-p ab --no-timestamps --no-index"
Q="$OBS/opt/usr/bin/quilt"
n=0
while :; do
  nxt=$("$Q" next 2>/dev/null) || break; [ -n "$nxt" ] || break
  "$Q" push -q --refresh >/dev/null 2>&1 && n=$((n+1)) || { echo "  push failed at $nxt" >&2; break; }
done
echo "  $n refreshed"
"$Q" pop -a -q >/dev/null 2>&1
rm -rf "$WORK/.pc"

echo "== 6. generate the .dsc against the OBS orig =="
rm -f "$OUT/linux_$UP.orig.tar."* "$OUT/linux_$VER.dsc" "$OUT/linux_$VER.debian.tar."*
cp "$ORIG" "$OUT/linux_$UP.orig.tar.xz"
(cd "$OUT" && dpkg-source --no-check -b "$WORK" 2>&1 | grep -iE 'error|warning' | head -5)
ls -la "$OUT"/linux_* 2>/dev/null
