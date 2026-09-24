#!/bin/bash
# Put a pending MOK enrollment request into an installed UEFI machine's NVRAM.
#
# What an operator does: boot the installed system with Secure Boot supported but
# switched off, run `mokutil --import`, switch Secure Boot on, reboot -- shim then
# starts MokManager. This does the first half and leaves the second to the caller.
#
# Two things here are not obvious.
#   * mokutil refuses on a machine whose firmware has no Secure Boot at all ("This
#     system doesn't support Secure Boot"), so the firmware has to be the Secure
#     Boot build with SecureBootEnable=0, not a non-enforcing build.
#   * mokutil skips a certificate that is already in the kernel's own keyring --
#     "Already in kernel trusted keyring. Skip" -- and still exits 0. The OBS
#     certificate is built into this kernel, so without --ignore-keyring nothing
#     is submitted; but the kernel's keyring is not shim's MOK list, which is what
#     GRUB and the kernel are verified against at boot.
#
# Usage: mok-import.sh <vars-in.fd> <vars-out.fd> <disk.qcow2> <cert.der> <hash-file> <virt-fw-vars> [ssh-port]
# On success <vars-out.fd> is <vars-in.fd> with the request added and Secure Boot
# switched back on, and the machine is powered off.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
VIN=${1:?vars-in} VOUT=${2:?vars-out} DISK=${3:?disk} CERT=${4:?cert.der} HASH=${5:?hash-file} VFV=${6:?virt-fw-vars}
PORT=${7:-2264}
NAME=uefi4
RUN=${OBS_DIR:-/home/aikon/danos/.obs}/run/$NAME
TMPV=$VOUT.off
G() { docker exec danos-robot timeout 120 sshpass -p vyatta ssh -p "$PORT" -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o ConnectTimeout=6 vyatta@192.168.203.1 "$1" 2>&1 | grep -v '^Welcome'; }

"$HERE/uefi-vm.sh" stop "$NAME" >/dev/null 2>&1
"$VFV" -i "$VIN" --set-false SecureBootEnable -d SHIM_VERBOSE -o "$TMPV" >/dev/null 2>&1 || exit 1
"$HERE/uefi-vm.sh" start "$NAME" "$TMPV" "$PORT" --disk "$DISK" >/dev/null || exit 1
for _ in $(seq 1 120); do grep -aq "login:" "$RUN/serial.log" && break; sleep 5; done
for _ in $(seq 1 40); do [ "$(G 'echo up' | tail -1)" = up ] && break; sleep 6; done
docker cp "$CERT" danos-robot:/tmp/mok-cert.der >/dev/null; docker cp "$HASH" danos-robot:/tmp/mok-hash.txt >/dev/null
docker exec danos-robot sh -c "sshpass -p vyatta scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P $PORT /tmp/mok-cert.der /tmp/mok-hash.txt vyatta@192.168.203.1:/tmp/" >/dev/null 2>&1
out=$(G 'echo vyatta | sudo -S -p "" sh -c "mokutil --sb-state; mokutil --import /tmp/mok-cert.der --hash-file /tmp/mok-hash.txt --ignore-keyring; echo rc=\$?; mokutil --list-new 2>&1 | grep -a Subject: | head -1"')
echo "$out"
echo "$out" | grep -q "SecureBoot disabled" && echo "$out" | grep -q "Subject:" || { echo "no pending request"; exit 2; }

python3 - "$RUN/monitor.sock" <<'PY'
import socket, sys, time
m = socket.socket(socket.AF_UNIX); m.connect(sys.argv[1]); m.settimeout(3)
m.sendall(b"system_powerdown\n"); time.sleep(1)
PY
P=$(cat "$RUN/qemu.pid"); for _ in $(seq 1 60); do kill -0 "$P" 2>/dev/null || break; sleep 3; done
"$HERE/uefi-vm.sh" stop "$NAME" >/dev/null 2>&1
"$VFV" -i "$TMPV" --set-true SecureBootEnable -o "$VOUT" >/dev/null 2>&1 || exit 1
rm -f "$TMPV"
echo "ready: $VOUT has the request pending and Secure Boot on"
