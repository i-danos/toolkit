#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-only
# Run one Secure Boot acceptance item and leave <item>.junit.xml (+ an unsigned evidence record).
#
#   accept-secure-boot.sh <item> <iso> [outdir]
#
# <item> is the JUnit classname and the key in handoff/verify/suite-config.json; each is one case file
# under cases/ run by verify-case.py with --exec local ON THE HOST (the cases drive QEMU themselves).
# outdir defaults to /home/aikon/danos/acceptance-p05/secure-boot-<suffix>. Only one QEMU may run at a
# time on this host: this script refuses to start while another qemu-system is running, because results
# gathered under contention (the 2026-10-31 05:35 cloud-init jitter) are not evidence.
#
# <outdir>/<item>.junit.xml, <item>.ev.json (unsigned) and accept.log are left in outdir. The JUnit path, its
# sha256 and the counts are printed at the end, and are in accept.log.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ITEM=${1:?usage: accept-secure-boot.sh <item> <iso> [outdir]}
ISO=${2:?iso}
BASE=${ACCEPT_BASE:-/home/aikon/danos/acceptance-p05}
case "$ITEM" in
  signed_boot_chain_live_iso)               CASE=sb-live-iso.yaml;     SUF=live-iso ;;
  signed_boot_chain_certificate_expiry)     CASE=sb-cert-expiry.yaml;  SUF=expiry ;;
  signed_boot_chain_kernel_view_and_add_image_check) CASE=sb-kernel-view.yaml; SUF=kernel-view ;;
  signed_boot_chain_installed_disk)          CASE=sb-installed-disk.yaml; SUF=installed-disk ;;
  signed_boot_chain_sbat_revocation)         CASE=sb-sbat.yaml; SUF=sbat ;;
  signed_boot_chain_mok_enrollment_flow)     CASE=sb-mok-flow.yaml; SUF=mok-flow ;;
  add_system_image_signing_check)           CASE=add-system-image-signing-check.yaml; SUF=add-image; NOQEMU=1 ;;
  *) echo "unknown item $ITEM" >&2; exit 2 ;;
esac
OUT=${3:-$BASE/secure-boot-$SUF}
[ -f "$ISO" ] || { echo "no such ISO: $ISO" >&2; exit 2; }
# (pgrep -x cannot match this name: comm is cut to 15 characters)
if [ -z "${NOQEMU:-}" ] && ps -eo comm= | grep -q '^qemu-system' && [ -z "${ACCEPT_ALLOW_QEMU:-}" ]; then
  echo "another qemu-system is running; refusing to start (one QEMU at a time)" >&2; exit 3
fi
TMPLOG=$OUT.accept.log.tmp          # outside $OUT: the case empties $OUT first
mkdir -p "$(dirname "$OUT")"
{
  echo "item=$ITEM case=$CASE iso=$ISO outdir=$OUT"
  echo "iso_sha256=$(sha256sum "$ISO" | cut -d' ' -f1)"
  mkdir -p "$OUT"
  python3 "$HERE/verify-case.py" "$HERE/cases/$CASE" --exec local --junit "$OUT/$ITEM.junit.xml" \
    --evidence "$OUT/$ITEM.ev.json" --iso "$ISO" --var "out=$OUT" --var "iso=$ISO" --var "vm_dir=$HERE"
  rc=$?
  echo "verify-case exit status $rc"
  python3 - "$OUT/$ITEM.junit.xml" <<'PY'
import hashlib, sys, xml.etree.ElementTree as ET
p = sys.argv[1]
r = ET.parse(p).getroot()
print("JUNIT path=%s sha256=%s tests=%s failures=%s skipped=%s" % (
    p, hashlib.sha256(open(p, "rb").read()).hexdigest(), r.get("tests"), r.get("failures"), r.get("skipped")))
PY
  exit "$rc"
} 2>&1 | tee "$TMPLOG"
rc=${PIPESTATUS[0]}
mv "$TMPLOG" "$OUT/accept.log"
exit "$rc"
