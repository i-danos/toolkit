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
OBS=/home/aikon/danos/.obs
OSC="$OBS/osc -A https://api.opensuse.org"
PRJ=home:i-danos
PKG=${1:?usage: push-api.sh <package> [commit message]}
MSG=${2:-Rebuild for Debian 13}

files=$(ls "$OBS/dsc/${PKG}_"*.dsc "$OBS/dsc/${PKG}_"*.tar.* 2>/dev/null)
[ -n "$files" ] || { echo "no files for $PKG under dsc/" >&2; exit 1; }

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
