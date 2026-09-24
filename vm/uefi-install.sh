#!/bin/bash
# Install the ISO to a blank disk on a UEFI + Secure Boot machine, then boot the
# installed disk. The sequence the UEFI tests all start from.
#
# Usage: uefi-install.sh <iso> <workdir> <vars-with-mok.fd> [name] [ssh-port]
#
# Leaves, in <workdir>: disk.qcow2 (the installed disk), vars.fd (the NVRAM the
# installer wrote its boot entry into -- reuse it, a fresh one has no entry),
# install.log. The machine is left RUNNING from the installed disk.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ISO=${1:?usage: uefi-install.sh <iso> <workdir> <vars-with-mok.fd> [name] [ssh-port]}
W=${2:?workdir}
MOK_VARS=${3:?vars.fd with the OBS certificate enrolled}
NAME=${4:-uefi3}
PORT=${5:-2263}
RUN=${OBS_DIR:-/home/aikon/danos/.obs}/run/$NAME
mkdir -p "$W"
rm -f "${W:?}/disk.qcow2" "${W:?}/vars.fd" "${W:?}/install.log"
qemu-img create -q -f qcow2 "$W/disk.qcow2" 20G || exit 1
cp "$MOK_VARS" "$W/vars.fd"

echo "== live boot from the ISO"
"$HERE/uefi-vm.sh" start "$NAME" "$W/vars.fd" "$PORT" --cdrom "$ISO" --disk "$W/disk.qcow2" || exit 1
"$HERE/grub-pick.py" "$RUN" 2 --wait 900 || { echo "no GRUB menu"; exit 3; }
for _ in $(seq 1 200); do grep -aq "login:" "$RUN/serial.log" && break; sleep 5; done
grep -aq "login:" "$RUN/serial.log" || { echo "live system never reached a login"; exit 4; }

echo "== install image"
timeout 1900 "$HERE/console-install.py" "$RUN/console.sock" --user tmpuser --password tmppwd \
  --admin-user vyatta --admin-password vyatta --timeout 1800 > "$W/install.log" 2>&1
grep -aq "Setting up grub on /dev/vda: OK" "$W/install.log" || { echo "grub did not install"; tail -5 "$W/install.log"; exit 5; }

echo "== clean power-off, then boot the installed disk"
python3 - "$RUN/monitor.sock" <<'PY'
import socket, sys, time
m = socket.socket(socket.AF_UNIX); m.connect(sys.argv[1]); m.settimeout(3)
m.sendall(b"system_powerdown\n"); time.sleep(1)
PY
P=$(cat "$RUN/qemu.pid"); for _ in $(seq 1 100); do kill -0 "$P" 2>/dev/null || break; sleep 3; done
"$HERE/uefi-vm.sh" stop "$NAME"
"$HERE/uefi-vm.sh" start "$NAME" "$W/vars.fd" "$PORT" --disk "$W/disk.qcow2" || exit 1
for _ in $(seq 1 240); do grep -aq "login:" "$RUN/serial.log" && { echo "installed system is at a login prompt"; exit 0; }; sleep 5; done
echo "installed system never reached a login prompt"; exit 6
