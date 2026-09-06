#!/bin/bash
# Push the current version of a package from dsc/ to OBS, overwriting whatever
# is there.
#
# How this differs from upload.sh: upload.sh skips anything already on OBS so a
# batch can be resumed, which suits the first bulk upload. Re-pushing the same
# version after a fix has to go through here.

set -u
# OBS_DIR is where the operational state lives -- dsc/ (generated source
# packages), the osc wrapper, run/ (console sockets), fixes/. It is deliberately
# separate from this toolkit: the scripts are worth keeping in version control,
# 2 GB of build output is not. Override it if your working directory differs.
OBS=${OBS_DIR:-${OBS_DIR:-/home/aikon/danos/.obs}}
OSC="$OBS/osc -A https://api.opensuse.org"
PRJ=home:i-danos

for p in "$@"; do
  # Newest by version, not "head -1". dsc/ accumulates -- mk-dsc.sh writes the
  # current version and never removes the previous one, and 12 packages there
  # hold two or more -- so the lowest version sorts first: 1.15.3 ahead of
  # 1.16.0. upload.sh had the same bug and it was silent, because the name it
  # then asked OBS about was a version nobody was uploading.
  ver=$(ls "$OBS/dsc/${p}_"*.dsc 2>/dev/null | sed "s|.*/${p}_||; s|\.dsc$||" | sort -V | tail -1)
  if [ -z "$ver" ]; then printf '  %-42s SKIP  not in dsc/\n' "$p"; continue; fi
  dsc="$OBS/dsc/${p}_${ver}.dsc"

  w=$(mktemp -d)
  if ! timeout 120 $OSC co "$PRJ" "$p" -o "$w/co" < /dev/null >/dev/null 2>&1; then
    printf '  %-42s FAIL  checkout\n' "$p"; rm -rf "$w"; continue
  fi
  # Clear the old files first, so a version bump does not leave both behind
  rm -f "$w/co/"*.dsc "$w/co/"*.tar.* 2>/dev/null
  # Only the chosen version, and take its tarball names from the .dsc's own
  # Files: list. Copying every match puts two source packages in one OBS
  # directory, which OBS cannot build -- it sits before scheduling, in no
  # column of osc results. Globbing on the version instead misses a quilt
  # package's debian tarball, whose name carries an extra component
  # (linux_6.12.107-1vyatta1.debian.tar.xz).
  cp "$dsc" "$w/co/" || { printf '  %-42s FAIL  copy\n' "$p"; rm -rf "$w"; continue; }
  while read -r f; do
    [ -n "$f" ] || continue
    cp "$OBS/dsc/$f" "$w/co/" 2>/dev/null
  done < <(awk '/^Files:/{f=1; next} /^[^ ]/{f=0} f && NF>=3 {print $3}' "$dsc")

  if (cd "$w/co" && $OSC addremove < /dev/null >/dev/null 2>&1 \
      && $OSC ci -m "${MSG:-Rebuild for Debian 13}" < /dev/null >/dev/null 2>&1); then
    printf '  %-42s OK\n' "$p"
  else
    printf '  %-42s FAIL  commit\n' "$p"
  fi
  rm -rf "$w"
done
