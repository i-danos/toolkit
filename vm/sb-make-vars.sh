#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-only
# A UEFI variable store for the Secure Boot tests: Microsoft's keys (OVMF_VARS_4M.ms.fd) plus, unless
# NO_MOK=1, the signer certificate of the ISO's GRUB and kernel enrolled as a MOK, which is the state of a machine
# whose operator has been through MokManager. The same construction verify-secure-boot.sh uses for T2.
#
# DB_TRUST=1: no MOK, the certificate goes into db instead.
#
# Usage: sb-make-vars.sh <iso> <outdir> <virt-fw-vars>
# Leaves <outdir>/vars.fd and <outdir>/obs-signer.pem (the certificate), and prints their sha256.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ISO=${1:?usage: sb-make-vars.sh <iso> <outdir> <virt-fw-vars>}
OUT=${2:?outdir}
VFV=${3:?virt-fw-vars}
VARS_MS=${VARS_MS:-/usr/share/OVMF/OVMF_VARS_4M.ms.fd}
SHIM_GUID=605dab50-e046-4300-abb6-3dd810dd8b23
mkdir -p "$OUT/inspect"
python3 "$HERE/efi-inspect.py" "$ISO" "$OUT/inspect" > "$OUT/inspect.txt" || { echo "BLOCKED: efi-inspect failed"; exit 1; }
[ -s "$OUT/inspect/grubx64.signer.pem" ] || { echo "BLOCKED: no signer certificate"; exit 1; }
cp "$OUT/inspect/grubx64.signer.pem" "$OUT/obs-signer.pem"
if [ -n "${DB_TRUST:-}" ]; then
  # the OBS certificate in the firmware db instead of a MOK: shim accepts it (it checks db before MokList), so the
  # machine boots with an EMPTY MokList and the MOK enrolment flow has something real to enrol
  "$VFV" -i "$VARS_MS" --add-db "$SHIM_GUID" "$OUT/obs-signer.pem" -o "$OUT/vars.fd" >/dev/null 2>&1 \
    || { echo "BLOCKED: virt-fw-vars could not add the db entry"; exit 1; }
elif [ -n "${NO_MOK:-}" ]; then
  cp "$VARS_MS" "$OUT/vars.fd"
else
  "$VFV" -i "$VARS_MS" --add-mok "$SHIM_GUID" "$OUT/obs-signer.pem" -o "$OUT/vars.fd" >/dev/null 2>&1 \
    || { echo "BLOCKED: virt-fw-vars could not enrol the MOK"; exit 1; }
fi
echo "vars.fd $(sha256sum "$OUT/vars.fd" | cut -d' ' -f1) mok=$([ -n "${NO_MOK:-}${DB_TRUST:-}" ] && echo no || echo yes) db-trust=${DB_TRUST:+yes}"
echo "obs-signer.pem $(sha256sum "$OUT/obs-signer.pem" | cut -d' ' -f1) $(openssl x509 -in "$OUT/obs-signer.pem" -noout -subject -enddate | tr '\n' ' ')"
