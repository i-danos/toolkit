#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-only
# The MOK enrolment flow for real: `mokutil --import` in the installed guest, MokManager "Enroll MOK" driven over the
# serial console (what it prints is read, never guessed), then the key in `mokutil --list-enrolled` after the reboot.
#
# For there to be something to enrol, the machine must boot with an EMPTY MokList: the OBS signing certificate goes into
# the firmware db for this run (sb-make-vars.sh DB_TRUST=1; shim checks db before MokList), so shim, GRUB and the
# kernel boot and the MOK enrolment is the only thing adding the certificate to MokList. KVM -cpu host, every wait
# capped, trap cleanup (sb-lib.sh).
#
# Usage: verify-sb-mok-flow.sh <iso> <outdir> <virt-fw-vars>
# SB_REUSE_DIR=<dir with disk0.qcow2 vars0.fd> skips the install (development only; the case never sets it).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ISO=${1:?iso}; OUT=${2:?outdir}; VFV=${3:?virt-fw-vars}
. "$HERE/sb-lib.sh"
sb_init sbmok "${SBMOK_PORT:-2273}"
if sb_other_qemu; then echo "REFUSED: another qemu-system is running"; exit 2; fi
mkdir -p "$OUT"; : > "$OUT/results.txt"
R() { echo "$*" >> "$OUT/results.txt"; }
echo "qemu: -enable-kvm -cpu host -smp 2 -m 3072 -machine q35,smm=on, OVMF secboot, guest clock: host"
echo "caps: boot=${SB_BOOT_CAP}s install=${SB_INSTALL_CAP}s"
R "iso_sha256=$(sha256sum "$ISO" | cut -d' ' -f1)"
PW=${SBMOK_PW:-mokpw1234}

DB_TRUST=1 bash "$HERE/sb-make-vars.sh" "$ISO" "$OUT" "$VFV" > "$OUT/make-vars.out" 2>&1 || { R "STAGE vars FAIL"; cat "$OUT/make-vars.out"; exit 3; }
if [ -n "${SB_REUSE_DIR:-}" ]; then
  cp "$SB_REUSE_DIR/disk0.qcow2" "$OUT/disk.qcow2"; cp "$SB_REUSE_DIR/vars0.fd" "$OUT/vars.fd"; R "stage-install reused"
else
  qemu-img create -q -f qcow2 "$OUT/disk.qcow2" 20G || exit 3
  sb_install "$ISO" "$OUT/vars.fd" "$OUT/disk.qcow2" "$OUT/install.log"; rc=$?
  R "stage-install rc=$rc"; [ $rc -eq 0 ] || exit 4
  cp "$OUT/disk.qcow2" "$OUT/disk0.qcow2"; cp "$OUT/vars.fd" "$OUT/vars0.fd"
fi
sb_boot_disk "$OUT/vars.fd" "$OUT/disk.qcow2"; rc=$?
R "stage-boot rc=$rc"; [ $rc -eq 0 ] || exit 5
sb_make_superuser "$OUT/superuser.out" || { R "stage-superuser FAIL"; exit 6; }
SUDO="echo vyatta | sudo -S -p ''"

# the certificate, as DER, into the guest in chunks; its sha256 there must equal the one here
openssl x509 -in "$OUT/obs-signer.pem" -outform der -out "$OUT/obs.der"
openssl x509 -in "$OUT/obs-signer.pem" -noout -issuer -subject -serial -fingerprint -sha1 -nameopt RFC2253 > "$OUT/openssl-view.txt"
R "cert-sha256=$(sha256sum "$OUT/obs.der" | cut -d' ' -f1)"
B64=$(base64 -w0 "$OUT/obs.der")
sb_guest 'rm -f /tmp/obs.b64' > /dev/null 2>&1
while [ -n "$B64" ]; do sb_guest "printf '%s' ${B64:0:300} >> /tmp/obs.b64" > /dev/null 2>&1; B64=${B64:300}; done
sb_guest 'base64 -d /tmp/obs.b64 > /tmp/obs.der; sha256sum /tmp/obs.der' > "$OUT/guest-cert.out" 2>&1
sb_guest "mokutil --generate-hash=$PW > /tmp/mokhash; cat /tmp/mokhash" > /dev/null 2>&1
sb_guest "$SUDO mokutil --list-enrolled | grep -c 'Subject:'" > "$OUT/enrolled-before.out" 2>&1
sb_guest "$SUDO mokutil --import /tmp/obs.der --hash-file /tmp/mokhash" > "$OUT/import.out" 2>&1
sb_guest "$SUDO mokutil --list-new" > "$OUT/list-new.out" 2>&1
# the plain import is skipped because the kernel already carries the OBS certificate (.builtin_trusted_keys); mokutil's
# own switch for that is --ignore-keyring, and it is what queues the request
sb_guest "$SUDO mokutil --import /tmp/obs.der --hash-file /tmp/mokhash --ignore-keyring" > "$OUT/import-ignore-keyring.out" 2>&1
sb_guest "$SUDO mokutil --list-new" > "$OUT/list-new-ignore-keyring.out" 2>&1
sb_guest "$SUDO mokutil --sb-state" > "$OUT/sb-state-before.out" 2>&1
sb_guest 'cat /proc/keys | grep -E "keyring +[.]builtin|asymmetri" | cut -c1-140' > "$OUT/kernel-keys.out" 2>&1

# Control: a throwaway certificate that is NOT in the kernel's keyring or db, so mokutil can queue it. It shows whether the
# import + MokManager walk + enrolment work at all, apart from the OBS certificate (which this machine already trusts,
# and which mokutil therefore refuses to queue).
openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -out "$OUT/control.pem" -days 30 -subj "/CN=sb-control-mok/O=danos-acceptance" >/dev/null 2>&1
openssl x509 -in "$OUT/control.pem" -outform der -out "$OUT/control.der"
openssl x509 -in "$OUT/control.pem" -noout -issuer -subject -serial -fingerprint -sha1 -nameopt RFC2253 > "$OUT/control-openssl-view.txt"
B64=$(base64 -w0 "$OUT/control.der")
sb_guest 'rm -f /tmp/c.b64' > /dev/null 2>&1
while [ -n "$B64" ]; do sb_guest "printf '%s' ${B64:0:300} >> /tmp/c.b64" > /dev/null 2>&1; B64=${B64:300}; done
sb_guest 'base64 -d /tmp/c.b64 > /tmp/control.der; sha256sum /tmp/control.der' > "$OUT/guest-control.out" 2>&1
sb_guest "$SUDO mokutil --import /tmp/control.der --hash-file /tmp/mokhash" > "$OUT/control-import.out" 2>&1
sb_guest "$SUDO mokutil --list-new" > "$OUT/control-list-new.out" 2>&1

# reboot into MokManager and drive it
OFF=$(stat -c %s "$SB_RUN/serial.log")
timeout 60 "$HERE/console.py" "$SB_RUN/console.sock" vyatta vyatta "$SUDO reboot" > /dev/null 2>&1
timeout "$((${SB_MM_WAIT:-300} + 600))" python3 "$HERE/mokmanager-drive.py" "$SB_RUN/console.sock" "$PW" "$OUT" --wait "${SB_MM_WAIT:-300}" > "$OUT/mokmanager-drive.out" 2>&1; mrc=$?
R "stage-mokmanager rc=$mrc"
cat "$OUT/mokmanager-drive.out" >> "$OUT/results.txt"
end=$(( $(date +%s) + SB_BOOT_CAP )); up=no
while [ "$(date +%s)" -lt "$end" ]; do
  tail -c +"$((OFF + 1))" "$SB_RUN/serial.log" | grep -aq 'login:' && { up=yes; break; }; sleep 3
done
R "stage-reboot login=$up"
cp "$SB_RUN/serial.log" "$OUT/serial.log"
if [ "$up" = yes ]; then
  sleep 5
  sb_guest "$SUDO mokutil --list-enrolled" > "$OUT/enrolled-after.out" 2>&1
  sb_guest "$SUDO mokutil --sb-state" > "$OUT/sb-state-after.out" 2>&1
  sb_guest "$SUDO mokutil --list-new" > "$OUT/list-new-after.out" 2>&1
fi
exit 0
