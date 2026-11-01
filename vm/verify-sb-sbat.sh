#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-only
# SBAT revocation through shim: the same Secure Boot boot (OBS certificate as MOK, real OVMF, KVM -cpu host) twice,
# differing ONLY in the SbatLevel variable written into the variable store: "grub,5" (the generation GRUB carries:
# must boot) and "grub,6" (revokes it: shim must refuse). The level text is a full SBAT revocation list, first line
# "sbat,1,<date>" included -- without that line shim ignores the variable (an earlier attempt wrote just "grub,6"
# and saw no effect). The stock Microsoft-keys store is enough; no self-built PK/KEK/db was needed.
#
# Usage: verify-sb-sbat.sh <iso> <outdir> <virt-fw-vars>
# Writes: results.txt ("grub5 <T2 verdict>", "grub6 <T2 verdict>"), grub5/ and grub6/ (verify-secure-boot.sh output)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ISO=${1:?iso}; OUT=${2:?outdir}; VFV=${3:?virt-fw-vars}
if ps -eo comm= | grep -q '^qemu-system'; then echo "REFUSED: another qemu-system is running"; exit 2; fi
mkdir -p "$OUT"; : > "$OUT/results.txt"
R() { echo "$*" >> "$OUT/results.txt"; }
echo "qemu: -enable-kvm -cpu host -smp 2 -m 3072 -machine q35,smm=on, OVMF secboot, guest clock: host"
R "iso_sha256=$(sha256sum "$ISO" | cut -d' ' -f1)"
for g in 5 6; do
  D=$OUT/grub$g; rm -rf "$D"
  SBAT_LEVEL=$'sbat,1,2026010100\n'"grub,$g"$'\n' ONLY=T2 timeout 900 bash "$HERE/verify-secure-boot.sh" "$ISO" "$D" "$VFV" > "$OUT/grub$g.stdout" 2>&1
  R "grub$g rc=$? $(grep -aE '^T2 ' "$D/results.txt" 2>/dev/null || echo 'T2 no-result')"
  R "grub$g level=$(tr '\n' '|' < "$D/sbat-level.txt" 2>/dev/null)"
done
exit 0
