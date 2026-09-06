#!/bin/bash
# Upload a package's source files straight through the OBS API, without an
# osc checkout.
#
# Why not push.sh: `osc co` first pulls down everything already on OBS. The
# kernel orig is 153 MB, so the checkout times out on the download alone and
# leaves the working copy half-broken (osc then says "Please run
# 'osc repairwc .'").
#
# The flow is the standard OBS two-step:
#   1) PUT /source/PRJ/PKG/FILE?rev=repository   put the file in the staging area
#   2) POST /source/PRJ/PKG?cmd=commitfilelist   commit a file list; anything not
#      listed is deleted, which is exactly what keeps old and new versions from
#      coexisting.

set -u
# OBS_DIR is where the operational state lives -- dsc/ (generated source
# packages), the osc wrapper, run/ (console sockets), fixes/. It is deliberately
# separate from this toolkit: the scripts are worth keeping in version control,
# 2 GB of build output is not. Override it if your working directory differs.
OBS=${OBS_DIR:-${OBS_DIR:-/home/aikon/danos/.obs}}
OSC="$OBS/osc -A https://api.opensuse.org"
PRJ=home:i-danos
PKG=${1:?usage: push-api.sh <package> [commit message]}
MSG=${2:-Rebuild for Debian 13}

# One version, the newest, and its own tarballs. Uploading every match puts two
# source packages in one OBS directory, which OBS cannot build: it sits before
# scheduling, in no column of osc results at all. dsc/ accumulates -- 12
# packages there hold two or more versions -- so this is reachable today, and
# the tarball names come from the .dsc's Files: list because a quilt package's
# debian tarball carries an extra name component.
VER=$(ls "$OBS/dsc/${PKG}_"*.dsc 2>/dev/null | sed "s|.*/${PKG}_||; s|\.dsc$||" | sort -V | tail -1)
[ -n "$VER" ] || { echo "no files for $PKG under dsc/" >&2; exit 1; }
DSC="$OBS/dsc/${PKG}_${VER}.dsc"
files="$DSC"
while read -r t; do
  [ -n "$t" ] || continue
  [ -f "$OBS/dsc/$t" ] || { echo "$t named in the .dsc is missing" >&2; exit 1; }
  files="$files $OBS/dsc/$t"
done < <(awk '/^Files:/{f=1; next} /^[^ ]/{f=0} f && NF>=3 {print $3}' "$DSC")

for f in $files; do
  b=$(basename "$f")
  printf '  upload %-46s %8s  ' "$b" "$(du -h "$f" | cut -f1)"
  ok=0
  for i in 1 2 3 4 5 6 7 8; do
    if timeout 900 $OSC api -X PUT -T "$f" \
         "/source/$PRJ/$PKG/$b?rev=repository" < /dev/null >/dev/null 2>&1; then
      ok=1; break
    fi
    printf "retry%d " "$i"; sleep 45
  done
  [ $ok -eq 1 ] && echo "OK" || { echo "FAILED"; exit 1; }
done

# File list: name only what was just uploaded; OBS deletes the rest of the package
{
  echo '<directory>'
  for f in $files; do
    printf '  <entry name="%s" md5="%s"/>\n' "$(basename "$f")" "$(md5sum "$f" | cut -d' ' -f1)"
  done
  echo '</directory>'
} > /tmp/filelist.xml

echo "  committing file list..."
timeout 300 $OSC api -X POST -f /tmp/filelist.xml \
  "/source/$PRJ/$PKG?cmd=commitfilelist&comment=$(printf '%s' "$MSG" | sed 's/ /%20/g')" \
  < /dev/null 2>&1 | grep -oE 'rev="[0-9]+"|<status[^>]*>' | head -2
echo "  done"
