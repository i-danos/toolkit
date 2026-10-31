#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-only
# What the installed system itself says about Secure Boot, and what `add system image` says about its signing
# check. One install (Secure Boot, KVM -cpu host), one boot of the installed disk, evidence collected over
# the serial console. Hard caps on every wait and a trap that kills the guest: see sb-lib.sh.
#
# Usage: verify-sb-kernel-view.sh <iso> <outdir> <virt-fw-vars>
# Writes: results.txt (one "<key> <value>" per line), mokutil.out, dmesg.out, lockdown.out, addimage.out,
#         install.log, serial-installed.log, vars.fd, disk.qcow2
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ISO=${1:?iso}; OUT=${2:?outdir}; VFV=${3:?virt-fw-vars}
. "$HERE/sb-lib.sh"
sb_init sbkv "${SBKV_PORT:-2271}"
if sb_other_qemu; then echo "REFUSED: another qemu-system is running"; exit 2; fi
mkdir -p "$OUT"; : > "$OUT/results.txt"
R() { echo "$*" >> "$OUT/results.txt"; }
echo "qemu: -enable-kvm -cpu host -smp 2 -m 3072 -machine q35,smm=on, OVMF secboot, guest clock: host"
echo "caps: boot=${SB_BOOT_CAP}s install=${SB_INSTALL_CAP}s"
R "iso_sha256=$(sha256sum "$ISO" | cut -d' ' -f1)"

bash "$HERE/sb-make-vars.sh" "$ISO" "$OUT" "$VFV" > "$OUT/make-vars.out" 2>&1 || { R "STAGE vars FAIL"; cat "$OUT/make-vars.out"; exit 3; }
qemu-img create -q -f qcow2 "$OUT/disk.qcow2" 20G || exit 3

# ISO served to the guest as the "image" to add (the guest reaches the host at 10.0.2.2)
PORT=${SBKV_HTTP:-8771}; SRV=$(mktemp -d)
ln -s "$ISO" "$SRV/upg.iso"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SRV" >/dev/null 2>&1 & SB_BG_PIDS+=($!)

sb_install "$ISO" "$OUT/vars.fd" "$OUT/disk.qcow2" "$OUT/install.log"; rc=$?
R "stage-install rc=$rc"; [ $rc -eq 0 ] || exit 4
sb_boot_disk "$OUT/vars.fd" "$OUT/disk.qcow2"; rc=$?
R "stage-boot rc=$rc"; [ $rc -eq 0 ] || exit 5
sb_make_superuser "$OUT/superuser.out" || { R "stage-superuser FAIL"; exit 6; }

SUDO="echo vyatta | sudo -S -p ''"
sb_guest 'mokutil --sb-state' > "$OUT/mokutil.out" 2>&1
sb_guest 'cat /sys/kernel/security/lockdown' > "$OUT/lockdown.out" 2>&1
sb_guest "$SUDO dmesg | grep -i 'secure boot'" > "$OUT/dmesg.out" 2>&1
sb_guest "$SUDO timeout 120 /opt/vyatta/sbin/vyatta-install-image http://10.0.2.2:$PORT/upg.iso < /dev/null" > "$OUT/addimage.out" 2>&1
cp "$SB_RUN/serial.log" "$OUT/serial-installed.log"
R "stage-collect done"
exit 0
