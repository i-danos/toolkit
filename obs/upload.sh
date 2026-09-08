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
# OBS_DIR is where the operational state lives -- dsc/ (generated source
# packages), the osc wrapper, run/ (console sockets), fixes/. It is deliberately
# separate from this toolkit: the scripts are worth keeping in version control,
# 2 GB of build output is not. Override it if your working directory differs.
OBS=${OBS_DIR:-${OBS_DIR:-/home/aikon/danos/.obs}}
# Every osc call in this script runs without a controlling terminal.
#
# oscrc uses TransientCredentialsManager: the password is held in one osc
# process and never written to disk, so once the session cookie expires -- about
# a day -- osc asks for it again. It asks through /dev/tty, which "< /dev/null"
# does not cover, and "timeout" runs its child in a new process group. Reading
# the terminal from a background process group raises SIGTTIN, which *stops* the
# reader; timeout is in that same group, so it stops too and its alarm never
# fires. The result is a batch that hangs indefinitely, printing nothing at all,
# with both processes in state T. It looks like OBS is not answering.
#
# Under setsid there is no controlling terminal, getpass() cannot open one, and
# an expired session fails in about three seconds with EOFError instead.
OSC="setsid --wait $OBS/osc -A https://api.opensuse.org"
PRJ=home:i-danos
DSC="$OBS/dsc"
CO="$OBS/checkout"

# Probe authentication once and bail out on failure, rather than letting the
# whole batch run into it one package at a time.
check_auth() {
  if ! timeout 30 $OSC api /person/i-danos < /dev/null > /dev/null 2>&1; then
    echo "Authentication failed: the osc session has expired." >&2
    echo "oscrc stores no password (TransientCredentialsManager), so the session" >&2
    echo "cookie is all there is and it lasts about a day. Refresh it yourself:" >&2
    echo >&2
    echo "    $OBS/osc -A https://api.opensuse.org api /person/i-danos > /dev/null && echo OK" >&2
    echo >&2
    echo "then rerun this script. It never enters your password." >&2
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
  local dsc ver
  # dsc/ accumulates: mk-dsc.sh writes the current version and never removes the
  # previous one, so 12 packages there currently hold two or more. Both halves
  # of this used to go wrong.
  #
  # "head -1" took the lowest version, not the newest -- vyatta-protocols-frr
  # 1.15.3 ahead of 1.16.0 -- so the "already on OBS" check below asked about a
  # version nobody was uploading, never matched, and the resumable skip could
  # not work. And the copy took *every* matching .dsc and tarball, which puts
  # two source packages in one OBS directory. OBS builds one per directory and
  # cannot choose between them: the upload succeeds, the revision climbs, and
  # the package sits before scheduling, in no column of osc results at all.
  #
  # Pick the newest by version and carry only that pair.
  ver=$(ls "$DSC/${p}_"*.dsc 2>/dev/null | sed "s|.*/${p}_||; s|\.dsc$||" | sort -V | tail -1)
  if [ -z "$ver" ]; then
    printf '  %-42s SKIP  no %s_*.dsc under dsc/\n' "$p" "$p"; return 1
  fi
  dsc="$DSC/${p}_${ver}.dsc"

  # Resumable: skip if OBS already holds this exact source. The session cookie
  # expires after roughly 24 hours, so a batch that dies halfway through can be
  # rerun without starting over.
  #
  # Compare the content, not the name. This project accumulates changes into one
  # version -- 1.16.0 has carried PIM, BFD and RIP in turn -- so a name-only
  # check reports "already on OBS" for a source package that differs from the
  # one up there, and the summary counts that skip as an upload. A real change
  # then never reaches OBS while the run looks successful.
  #
  # The .dsc's own md5 is enough: it carries the checksums of its tarballs, so
  # any change anywhere in the source changes the .dsc too.
  local want remote_md5 local_md5
  want=$(basename "$dsc")
  local_md5=$(md5sum "$dsc" | cut -d' ' -f1)
  remote_md5=$(timeout 60 $OSC api "/source/$PRJ/$p" < /dev/null 2>/dev/null \
    | awk -v n="$want" 'match($0, /<entry name="[^"]*" md5="[^"]*"/) {
        e = substr($0, RSTART, RLENGTH)
        split(e, a, "\"")
        if (a[2] == n) print a[4]
      }' | head -1)
  if [ -n "$remote_md5" ] && [ "$remote_md5" = "$local_md5" ]; then
    # 2, not 0: the caller counts this separately. Reporting a skip as an
    # upload is how a change that never reached OBS still read as "1 uploaded".
    printf '  %-42s SKIP  identical source already on OBS\n' "$p"; return 2
  fi
  if [ -n "$remote_md5" ]; then
    printf '  %-42s changed since the copy on OBS, re-uploading\n' "$p"
  fi

  mkdir -p "$CO"
  # Create the package, ignoring the error if it already exists
  printf '<package name="%s" project="%s"><title>%s</title><description/></package>\n' \
    "$p" "$PRJ" "$p" > "$CO/.pkgmeta.xml"
  $OSC api -X PUT "/source/$PRJ/$p/_meta" -f "$CO/.pkgmeta.xml" < /dev/null > /dev/null 2>&1

  rm -rf "$CO/$p"; mkdir -p "$CO/$p"
  cp "$dsc" "$CO/$p/" || return 1
  # Take the tarball names from the .dsc's own Files: list rather than globbing
  # on the version. Globbing looks right and is not: a quilt package's debian
  # tarball carries an extra name component --
  # linux_6.12.107-1vyatta1.debian.tar.xz, not linux_6.12.107-1vyatta1.tar.xz --
  # so ${p}_${ver}.tar.* misses it and uploads a .dsc whose tarball is absent.
  # The Files: list is authoritative and needs no knowledge of the format.
  local f
  while read -r f; do
    [ -n "$f" ] || continue
    if ! cp "$DSC/$f" "$CO/$p/" 2>/dev/null; then
      printf '  %-42s FAIL  %s named in the .dsc is missing\n' "$p" "$f"
      rm -rf "$CO/$p"; return 1
    fi
  done < <(awk '/^Files:/{f=1; next} /^[^ ]/{f=0} f && NF>=3 {print $3}' "$dsc")

  ( cd "$CO" && $OSC co "$PRJ" "$p" -o "$p.co" < /dev/null > /dev/null 2>&1
    cp "$p/"* "$p.co/" 2>/dev/null
    cd "$p.co" && $OSC addremove < /dev/null > /dev/null 2>&1 \
      && $OSC ci -m "DANOS on Debian 13 (branch i-danos/2608)" < /dev/null > /dev/null 2>&1 )
  local rc=$?
  rm -rf "$CO/$p" "$CO/$p.co"
  if [ $rc -eq 0 ]; then
    # Record the commit this upload carried.
    #
    # Without it, "does OBS have my latest commit?" can only be approached
    # through the .dsc's md5, and that cannot answer it: .dsc generation is not
    # reproducible (quilt rewrites mtimes), so a regeneration alone makes the
    # md5 differ while the source is identical. check-obs-current.sh reported 46
    # packages as needing upload on exactly that basis, and the one sampled
    # against OBS differed by a single debian/.gitignore.
    [ -f "$DSC/${p}_${ver}.commit" ] && cp "$DSC/${p}_${ver}.commit" "$DSC/${p}_${ver}.uploaded"
    printf '  %-42s OK\n' "$p"
  else
    printf '  %-42s FAIL  upload\n' "$p"
  fi
  return $rc
}

check_auth

if [ "${1:-}" = "--meta-only" ]; then set_meta; exit $?; fi

set_meta || { echo "writing _meta failed, aborting." >&2; exit 1; }

pkgs=("$@")
if [ ${#pkgs[@]} -eq 0 ]; then
  mapfile -t pkgs < <(ls "$DSC"/*.dsc 2>/dev/null | xargs -n1 basename | sed 's/_[^_]*\.dsc$//' | sort -u)
fi

ok=0; fail=0; skip=0
for p in "${pkgs[@]}"; do
  push_pkg "$p"
  case $? in
    0) ok=$((ok+1)) ;;
    2) skip=$((skip+1)) ;;
    *) fail=$((fail+1)) ;;
  esac
done
echo
echo "$ok uploaded, $skip unchanged, $fail failed"
echo "build status: $OBS/osc -A https://api.opensuse.org results $PRJ"
