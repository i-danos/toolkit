#!/bin/bash
# Push the current version of a package from dsc/ to OBS, overwriting whatever
# is there.
#
# How this differs from upload.sh: upload.sh skips anything already on OBS so a
# batch can be resumed, which suits the first bulk upload. Re-pushing the same
# version after a fix has to go through here.

set -u
OBS=/home/aikon/danos/.obs
OSC="$OBS/osc -A https://api.opensuse.org"
PRJ=home:i-danos

for p in "$@"; do
  dsc=$(ls "$OBS/dsc/${p}_"*.dsc 2>/dev/null | head -1)
  if [ -z "$dsc" ]; then printf '  %-42s SKIP  not in dsc/\n' "$p"; continue; fi

  w=$(mktemp -d)
  if ! timeout 120 $OSC co "$PRJ" "$p" -o "$w/co" < /dev/null >/dev/null 2>&1; then
    printf '  %-42s FAIL  checkout\n' "$p"; rm -rf "$w"; continue
  fi
  # Clear the old files first, so a version bump does not leave both behind
  rm -f "$w/co/"*.dsc "$w/co/"*.tar.* 2>/dev/null
  cp "$OBS/dsc/${p}_"*.dsc "$OBS/dsc/${p}_"*.tar.* "$w/co/" 2>/dev/null

  if (cd "$w/co" && $OSC addremove < /dev/null >/dev/null 2>&1 \
      && $OSC ci -m "${MSG:-Rebuild for Debian 13}" < /dev/null >/dev/null 2>&1); then
    printf '  %-42s OK\n' "$p"
  else
    printf '  %-42s FAIL  commit\n' "$p"
  fi
  rm -rf "$w"
done
