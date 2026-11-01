#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-only
# The installed disk under OVMF Secure Boot: install onto a blank 20 GiB qcow2, read the ESP the installer
# wrote and who signed what is in it, boot the disk ALONE with the NVRAM the installer filled in, then flip
# one bit in a COPY of the installed grubx64.efi and require shim to refuse it. KVM, -cpu host; every wait is
# capped and a trap kills the guest (sb-lib.sh).
#
# Usage: verify-sb-installed-disk.sh <iso> <outdir> <virt-fw-vars>
# Writes: results.txt, install.log, esp-inspect.txt, esp/ (the installed ESP's files), serial-installed.log,
#         serial-tamper.log, disk.qcow2 (installed), tamper.qcow2 (the bit-flipped copy), vars.fd
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ISO=${1:?iso}; OUT=${2:?outdir}; VFV=${3:?virt-fw-vars}
. "$HERE/sb-lib.sh"
sb_init sbdisk "${SBDISK_PORT:-2272}"
if sb_other_qemu; then echo "REFUSED: another qemu-system is running"; exit 2; fi
mkdir -p "$OUT"; : > "$OUT/results.txt"
R() { echo "$*" >> "$OUT/results.txt"; }
echo "qemu: -enable-kvm -cpu host -smp 2 -m 3072 -machine q35,smm=on, OVMF secboot, guest clock: host"
echo "caps: boot=${SB_BOOT_CAP}s install=${SB_INSTALL_CAP}s"
R "iso_sha256=$(sha256sum "$ISO" | cut -d' ' -f1)"

bash "$HERE/sb-make-vars.sh" "$ISO" "$OUT" "$VFV" > "$OUT/make-vars.out" 2>&1 || { R "STAGE vars FAIL"; cat "$OUT/make-vars.out"; exit 3; }
qemu-img create -q -f qcow2 "$OUT/disk.qcow2" 20G || exit 3

sb_install "$ISO" "$OUT/vars.fd" "$OUT/disk.qcow2" "$OUT/install.log"; rc=$?
R "stage-install rc=$rc"
grep -aq 'Setting up grub on /dev/vda: OK' "$OUT/install.log" && R "grub-install=ok" || R "grub-install=missing"
[ $rc -eq 0 ] || exit 4

# the ESP, read from a raw copy (no root needed): GPT -> EFI System partition -> FAT reader
W=$(mktemp -d); trap 'rm -rf "$W"; sb_cleanup' EXIT INT TERM
qemu-img convert -f qcow2 -O raw "$OUT/disk.qcow2" "$W/d.raw" || exit 5
read -r ESP_START ESP_SIZE < <(sfdisk -J "$W/d.raw" | python3 -c '
import json,sys
for p in json.load(sys.stdin)["partitiontable"]["partitions"]:
    if p["type"].upper()=="C12A7328-F81F-11D2-BA4B-00A0C93EC93B": print(p["start"],p["size"]); break')
[ -n "${ESP_START:-}" ] || { R "stage-esp FAIL no EFI System partition"; exit 5; }
dd if="$W/d.raw" of="$W/esp.raw" bs=512 skip="$ESP_START" count="$ESP_SIZE" status=none
rm -rf "$OUT/esp-inspect"; python3 "$HERE/efi-inspect.py" --fat "$W/esp.raw" "$OUT/esp-inspect" > "$OUT/esp-inspect.txt" 2>&1
rm -rf "$OUT/esp"; cp -r "$OUT/esp-inspect/esp" "$OUT/esp"
R "esp-partition start=$ESP_START sectors=$ESP_SIZE"
R "esp-shim $(grep -a '/EFI/debian/shimx64.efi ' "$OUT/esp-inspect.txt" | sed 's/.*signer: /signer: /')"
R "esp-grub $(grep -a '/EFI/debian/grubx64.efi ' "$OUT/esp-inspect.txt" | sed 's/.*signer: /signer: /')"
GOFF=$(grep -a '/EFI/debian/grubx64.efi ' "$OUT/esp-inspect.txt" | sed -n 's/.*iso_offset=\([0-9]*\).*/\1/p')
GSIZE=$(stat -c %s "$OUT/esp/EFI/debian/grubx64.efi")
R "grub-sha256=$(sha256sum "$OUT/esp/EFI/debian/grubx64.efi" | cut -d' ' -f1)"

# tamper copy: flip the low bit of one byte in the middle of the installed grubx64.efi (inside the hashed
# image, away from the certificate table), then check the byte on the disk really is the flipped one
cp --sparse=always "$W/d.raw" "$W/t.raw"
TOFF=$(( ESP_START * 512 + GOFF + GSIZE / 2 ))
python3 - "$W/t.raw" "$TOFF" "$OUT/esp/EFI/debian/grubx64.efi" "$GSIZE" <<'PY'
import sys
p, off, orig, size = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
want = open(orig, "rb").read()[size // 2]
with open(p, "r+b") as f:
    f.seek(off); b = f.read(1)[0]
    assert b == want, "disk byte %02x at %d is not the ESP file's byte %02x: file not contiguous" % (b, off, want)
    f.seek(off); f.write(bytes([b ^ 1]))
print("flipped byte at disk offset %d: %02x -> %02x" % (off, b, b ^ 1))
PY
[ $? -eq 0 ] || { R "stage-tamper FAIL could not patch the copy"; exit 6; }
qemu-img convert -f raw -O qcow2 "$W/t.raw" "$OUT/tamper.qcow2"
R "tamper-offset=$TOFF"
rm -f "$W/d.raw" "$W/t.raw" "$W/esp.raw"

# 1) the installed disk alone, with the installer's NVRAM
sb_boot_disk "$OUT/vars.fd" "$OUT/disk.qcow2"; rc=$?
R "stage-boot-alone rc=$rc"
cp "$SB_RUN/serial.log" "$OUT/serial-installed.log"
"$HERE/uefi-vm.sh" stop "$SB_NAME" >/dev/null 2>&1

# 2) the tampered copy, same NVRAM (a copy, so the first boot's NVRAM writes are not what is under test)
cp "$OUT/vars.fd" "$OUT/vars-tamper.fd"
"$HERE/uefi-vm.sh" start "$SB_NAME" "$OUT/vars-tamper.fd" "$SB_PORT" --disk "$OUT/tamper.qcow2" || { R "stage-tamper-boot FAIL start"; exit 7; }
end=$(( $(date +%s) + ${SB_TAMPER_CAP:-300} )); res=timeout
while [ "$(date +%s)" -lt "$end" ]; do
  if grep -aq 'Security Violation' "$SB_RUN/serial.log"; then res=refused; break; fi
  if grep -aq 'login:' "$SB_RUN/serial.log"; then res=booted; break; fi
  sleep 3
done
R "tamper-result=$res"
cp "$SB_RUN/serial.log" "$OUT/serial-tamper.log"
exit 0
