#!/bin/bash
# Push the generated Debian source packages to home:i-danos on OBS and trigger
# the builds.
#
# Prerequisite: ~/.config/osc/oscrc already holds credentials for
#   api.opensuse.org. This script does not handle login — you have to enter the
#   password yourself (see README-OBS.md).
#
# Usage:
#   ./upload.sh --meta-only          write the project _meta only (2608 target)
#   ./upload.sh <pkg> [<pkg>...]     push the named packages
#   ./upload.sh                      push everything under dsc/

set -u
OBS=/home/aikon/danos/.obs
OSC="$OBS/osc -A https://api.opensuse.org"
PRJ=home:i-danos
DSC="$OBS/dsc"
CO="$OBS/checkout"

# Without credentials osc blocks on an interactive prompt and hangs there
# indefinitely. Probe authentication once with a timeout and bail out on
# failure, rather than letting the whole batch stall.
check_auth() {
  if ! timeout 30 $OSC api /person/i-danos < /dev/null > /dev/null 2>&1; then
    echo "Authentication failed: no usable credentials in ~/.config/osc/oscrc." >&2
    echo "Log in yourself per step 1 of README-OBS.md; this script never enters your password." >&2
    exit 1
  fi
}

set_meta() {
  echo "== writing project _meta (2608 / x86_64 build target) =="
  $OSC meta prj "$PRJ" -F "$OBS/project-meta.xml" < /dev/null || return 1
  $OSC meta prj "$PRJ" < /dev/null | grep -E 'repository|path|arch'
}

push_pkg() {
  local p="$1"
  local files
  files=$(ls "$DSC/${p}_"*.dsc 2>/dev/null | head -1)
  if [ -z "$files" ]; then
    printf '  %-42s SKIP  no %s_*.dsc under dsc/\n' "$p" "$p"; return 1
  fi

  # Resumable: skip if a .dsc of the same name is already on OBS. The session
  # cookie expires after roughly 24 hours, so a batch that dies halfway through
  # can be rerun without starting over.
  local want remote
  want=$(basename "$files")
  remote=$(timeout 60 $OSC ls "$PRJ" "$p" < /dev/null 2>/dev/null | grep -Fx "$want")
  if [ -n "$remote" ]; then
    printf '  %-42s SKIP  already on OBS\n' "$p"; return 0
  fi

  mkdir -p "$CO"
  # Create the package, ignoring the error if it already exists
  printf '<package name="%s" project="%s"><title>%s</title><description/></package>\n' \
    "$p" "$PRJ" "$p" > "$CO/.pkgmeta.xml"
  $OSC api -X PUT "/source/$PRJ/$p/_meta" -f "$CO/.pkgmeta.xml" < /dev/null > /dev/null 2>&1

  rm -rf "$CO/$p"; mkdir -p "$CO/$p"
  cp "$DSC/${p}_"*.dsc "$DSC/${p}_"*.tar.* "$CO/$p/" 2>/dev/null

  ( cd "$CO" && $OSC co "$PRJ" "$p" -o "$p.co" < /dev/null > /dev/null 2>&1
    cp "$p/"* "$p.co/" 2>/dev/null
    cd "$p.co" && $OSC addremove < /dev/null > /dev/null 2>&1 \
      && $OSC ci -m "DANOS on Debian 13 (branch i-danos/2608)" < /dev/null > /dev/null 2>&1 )
  local rc=$?
  rm -rf "$CO/$p" "$CO/$p.co"
  [ $rc -eq 0 ] && printf '  %-42s OK\n' "$p" || printf '  %-42s FAIL  upload\n' "$p"
  return $rc
}

check_auth

if [ "${1:-}" = "--meta-only" ]; then set_meta; exit $?; fi

set_meta || { echo "writing _meta failed, aborting." >&2; exit 1; }

pkgs=("$@")
if [ ${#pkgs[@]} -eq 0 ]; then
  mapfile -t pkgs < <(ls "$DSC"/*.dsc 2>/dev/null | xargs -n1 basename | sed 's/_[^_]*\.dsc$//' | sort -u)
fi

ok=0; fail=0
for p in "${pkgs[@]}"; do push_pkg "$p" && ok=$((ok+1)) || fail=$((fail+1)); done
echo
echo "$ok uploaded, $fail failed"
echo "build status: $OBS/osc -A https://api.opensuse.org results $PRJ"
