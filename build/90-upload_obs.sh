#!/bin/bash
# Upload a locally built Debian source package to home:i-danos.
#
# Two packages were only ever built locally -- the local build skips the OBS
# queue, which is why the ISO has vyatta-dataplane 3.14.36 and
# vyatta-security-vpn 2.19 while OBS has no such packages at all. Everything
# else in build_order.txt is on OBS already; those two are the whole gap.
#
# Uploading here PUBLISHES THE SOURCE. home: projects on build.opensuse.org are
# world-readable, so anything committed becomes public.
#
# osc is configured with TransientCredentialsManager, which keeps the password
# in memory only and never writes it to disk. That is the right setting, and it
# means every osc process asks again -- expect one prompt per call below, three
# per package. To be asked once instead, switch to the system keyring:
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
TAR="$DSC_DIR/${PKG}_${VER}.tar.xz"

for f in "$DSC" "$TAR"; do
  [ -f "$f" ] || { echo "missing $f -- generate the source package first" >&2; exit 1; }
done

# Verify the tarball against the checksum the .dsc records. A .dsc whose
# checksum does not match its tarball is rejected by the OBS build, but only
# after the upload and a scheduling round trip -- much cheaper to catch here.
want=$(awk '/^Checksums-Sha256:/{f=1;next} f&&/^ /{print $1; exit}' "$DSC")
got=$(sha256sum "$TAR" | awk '{print $1}')
if [ "$want" != "$got" ]; then
  echo "sha256 mismatch for $(basename "$TAR")" >&2
  echo "  .dsc records $want" >&2
  echo "  file is      $got" >&2
  exit 1
fi

echo "  package   $PKG"
echo "  version   $VER"
echo "  project   $PROJECT"
echo "  files     $(basename "$DSC"), $(basename "$TAR") ($(du -h "$TAR" | cut -f1))"
echo "  checksum  verified against the .dsc"
echo
echo "  This publishes the source publicly. Ctrl-C now if that is not intended."
echo "  Three osc calls follow; each asks for the password separately."
echo

meta=$(mktemp); trap 'rm -f "$meta"' EXIT
cat > "$meta" <<XML
<package name="$PKG" project="$PROJECT">
  <title>$PKG</title>
  <description>DANOS $PKG, built for the 2608 release.</description>
</package>
XML

api="/source/$PROJECT/$PKG"

echo "== 1/3  create or update the package =="
"$OSC" api -X PUT -T "$meta" "$api/_meta" > /dev/null

echo "== 2/3  upload $(basename "$DSC") =="
"$OSC" api -X PUT -T "$DSC" "$api/$(basename "$DSC")" > /dev/null

echo "== 3/3  upload $(basename "$TAR") =="
"$OSC" api -X PUT -T "$TAR" "$api/$(basename "$TAR")" > /dev/null

echo
echo "  done. Watch the build with:"
echo "    $OSC results $PROJECT $PKG"
