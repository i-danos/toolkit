#!/bin/bash
# Upload only the kernel's .dsc and debian.tar.xz; the server reuses the
# existing orig.
#
# Uploading the 147 MB orig fails reproducibly: Connection reset by peer at
# 85 MB / 231 s, averaging 367 KB/s, i.e. something in the middle cuts the
# connection after about four minutes. The download direction is fine.
# All three files are listed in commitfilelist; when the orig is not in the
# staging area, OBS reuses it from an existing revision by md5.
set -u
OBS=/home/aikon/danos/.obs
OSC="$OBS/osc -A https://api.opensuse.org"
MSG=${1:-Rebuild}
D=$OBS/dsc
for b in linux_6.12.101-1vyatta1.dsc linux_6.12.101-1vyatta1.debian.tar.xz; do
  printf '  upload %-42s ' "$b"
  timeout 300 $OSC api -X PUT -T "$D/$b" "/source/home:i-danos/linux/$b?rev=repository" < /dev/null >/dev/null 2>&1 \
    && echo OK || { echo FAILED; exit 1; }
done
{ echo '<directory>'
  for b in linux_6.12.101-1vyatta1.dsc linux_6.12.101-1vyatta1.debian.tar.xz linux_6.12.101.orig.tar.xz; do
    printf '  <entry name="%s" md5="%s"/>\n' "$b" "$(md5sum "$D/$b" | cut -d' ' -f1)"
  done
  echo '</directory>'; } > /tmp/fl.xml
echo "  committing file list..."
timeout 300 $OSC api -X POST -f /tmp/fl.xml \
  "/source/home:i-danos/linux?cmd=commitfilelist&comment=$(printf '%s' "$MSG" | sed 's/ /%20/g')" \
  < /dev/null 2>&1 | grep -oE 'rev="[0-9]+"' | head -1
