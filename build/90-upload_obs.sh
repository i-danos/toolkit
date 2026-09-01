#!/bin/bash
# Upload a locally built Debian source package to home:i-danos.
#
# vyatta-dataplane and vyatta-security-vpn are built locally rather than on OBS,
# because the local build skips the queue. That is why the 2608 ISO carries
# 3.14.36 and 2.19 -- and why OBS had been sitting on older sources that it was
# never actually building. See step 4 for what was wrong.
#
# Uploading here PUBLISHES THE SOURCE. home: projects on build.opensuse.org are
# world-readable, so anything committed becomes public.
#
# osc is configured with TransientCredentialsManager, which keeps the password
# in memory only and never writes it to disk. That is the right setting. The
# first call below prompts; the rest reuse the session cookie it leaves in
# ~/.local/state/osc/cookiejar. To avoid the prompt entirely, switch to the
# system keyring:
#
#     credentials_mgr_class=osc.credentials.KeyringCredentialsManager
#
# in ~/.config/osc/oscrc. That stores the password in the OS keyring rather than
# in plain text, but it is a real change to how the credential is held -- decide
# that yourself rather than because a script suggested it.
#
# Usage: 90-upload_obs.sh <package> <version>
#        90-upload_obs.sh vyatta-dataplane 3.14.36
#        90-upload_obs.sh vyatta-security-vpn 2.19

set -eu

PKG=${1:?usage: 90-upload_obs.sh <package> <version>}
VER=${2:?usage: 90-upload_obs.sh <package> <version>}

OBS=${OBS_DIR:-/home/aikon/danos/.obs}
OSC=${OSC:-$OBS/osc}
PROJECT=${OBS_PROJECT:-home:i-danos}
DSC_DIR=${DSC_DIR:-$OBS/dsc}

DSC="$DSC_DIR/${PKG}_${VER}.dsc"
[ -f "$DSC" ] || { echo "missing $DSC -- generate the source package first" >&2; exit 1; }

# Take the file list from the .dsc rather than assuming one tarball named after
# the package. Native packages carry a single <pkg>_<ver>.tar.xz; 3.0 (quilt)
# packages carry an orig tarball plus a debian one, and the kernel is the
# latter. Guessing the name meant this script could not upload linux at all,
# and the failure was at the precondition check, which is at least the cheap
# place for it.
FILES=$(awk '/^Checksums-Sha256:/{f=1;next} f&&/^ /{print $3} f&&!/^ /{exit}' "$DSC")
[ -n "$FILES" ] || { echo "no Checksums-Sha256 entries in $DSC" >&2; exit 1; }

# Verify every file against the checksum the .dsc records. A .dsc whose
# checksums do not match its tarballs is rejected by the OBS build, but only
# after the upload and a scheduling round trip -- and for the kernel, only
# after hours of compilation. Much cheaper to catch here.
for f in $FILES; do
  [ -f "$DSC_DIR/$f" ] || { echo "missing $DSC_DIR/$f" >&2; exit 1; }
  want=$(awk -v N="$f" '/^Checksums-Sha256:/{s=1;next} s&&$3==N{print $1; exit}' "$DSC")
  got=$(sha256sum "$DSC_DIR/$f" | awk '{print $1}')
  if [ "$want" != "$got" ]; then
    echo "sha256 mismatch for $f" >&2
    echo "  .dsc records $want" >&2
    echo "  file is      $got" >&2
    exit 1
  fi
done

echo "  package   $PKG"
echo "  version   $VER"
echo "  project   $PROJECT"
echo "  files     $(basename "$DSC")"
for f in $FILES; do echo "            $f ($(du -h "$DSC_DIR/$f" | cut -f1))"; done
echo "  checksum  all verified against the .dsc"
echo
echo "  This publishes the source publicly. Ctrl-C now if that is not intended."
echo "  Four osc calls follow. The first asks for the password; the rest"
echo "  reuse the session it establishes."
echo

meta=$(mktemp); trap 'rm -f "$meta"' EXIT
cat > "$meta" <<XML
<package name="$PKG" project="$PROJECT">
  <title>$PKG</title>
  <description>DANOS $PKG, built for the 2608 release.</description>
</package>
XML

api="/source/$PROJECT/$PKG"

echo "== 1/4  create or update the package =="
"$OSC" api -X PUT -T "$meta" "$api/_meta" > /dev/null

echo "== 2/4  upload $(basename "$DSC") =="
"$OSC" api -X PUT -T "$DSC" "$api/$(basename "$DSC")" > /dev/null

echo "== 3/4  upload the tarballs =="
for f in $FILES; do
  echo "  $f"
  "$OSC" api -X PUT -T "$DSC_DIR/$f" "$api/$f" > /dev/null
done

# Remove every other version from the package directory. OBS builds one source
# package per package directory and wants exactly one .dsc there; leaving the
# previous version behind gives it two, and it then has no way to choose. The
# symptom is quiet and easy to misread: the files upload fine, the revision
# number keeps climbing, and the package simply never appears in
# "osc results" -- it looks absent rather than stuck. vyatta-dataplane sat at
# rev 10 with 3.14.28, 3.14.34 and 3.14.36 all present and had never once been
# scheduled.
echo "== 4/4  remove other versions from the package directory =="
keep=$(printf '%s\n%s\n' "$(basename "$DSC")" "$FILES")
stale=$("$OSC" api "$api" \
  | sed -n 's/.*<entry name="\([^"]*\)".*/\1/p' \
  | grep -vxF "$keep" || true)

if [ -z "$stale" ]; then
  echo "  nothing to remove"
else
  for f in $stale; do
    echo "  deleting $f"
    "$OSC" api -X DELETE "$api/$f" > /dev/null
  done
fi

echo
echo "  done. Watch the build with:"
echo "    $OSC results $PROJECT $PKG"
echo "  If it still does not appear, the authoritative answer is in:"
echo "    $OSC api /build/$PROJECT/2608/x86_64/$PKG/_status"
