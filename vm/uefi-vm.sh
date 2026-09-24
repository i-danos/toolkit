#!/bin/bash
# Start or stop a QEMU/OVMF machine with Secure Boot on, for the UEFI tests.
#
# The serial port is one chardev with two uses at once: a socket a driver can
# talk to (console.py, console-install.py), and a logfile that records every
# byte from the very first, so nothing the firmware or GRUB prints before a
# driver connects is lost. A plain socket loses that; a socket that waits for a
# client blocks the machine, and on a host where qemu can take minutes to start
# it made a stuck machine look like a refusal.
#
# Usage: uefi-vm.sh start <name> <vars.fd> <ssh-port> [--cdrom ISO] [--disk QCOW2]
#        uefi-vm.sh stop  <name>
#
# Files land in $OBS_DIR/run/<name>/: console.sock, monitor.sock, serial.log,
# qemu.pid, qemu.log. <vars.fd> is used in place, not copied -- boot entries the
# installer writes into NVRAM have to survive to the next boot.
set -u
CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.secboot.fd}
cmd=${1:?usage: uefi-vm.sh start|stop <name> ...}
NAME=${2:?name}
RUN=${OBS_DIR:-/home/aikon/danos/.obs}/run/$NAME

pid_of() {
  local p; p=$(cat "$RUN/qemu.pid" 2>/dev/null)
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  tr '\0' ' ' </proc/$p/cmdline 2>/dev/null | grep -q -- "-name $NAME " || return 1
  echo "$p"
}

case "$cmd" in
stop)
  p=$(pid_of) || { rm -f "${RUN:?}"/*.sock "${RUN:?}/qemu.pid"; exit 0; }
  kill -9 "$p" 2>/dev/null
  # A killed qemu can take a long time to go away on this host, and until it
  # does it holds the disk's write lock.
  while kill -0 "$p" 2>/dev/null; do sleep 0.5; done
  rm -f "${RUN:?}"/*.sock "${RUN:?}/qemu.pid"
  ;;
start)
  VARS=${3:?vars.fd}; SSHPORT=${4:?ssh port}; shift 4
  CD=""; DISK=""
  while [ $# -gt 0 ]; do
    case "$1" in --cdrom) CD=$2; shift 2 ;; --disk) DISK=$2; shift 2 ;; *) echo "unknown $1" >&2; exit 2 ;; esac
  done
  mkdir -p "$RUN"
  pid_of >/dev/null && { echo "$NAME already running" >&2; exit 1; }
  rm -f "${RUN:?}"/*.sock "$RUN/serial.log"
  args=(-name "$NAME" -enable-kvm -cpu host -smp 2 -m 3072
        -machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on
        -drive if=pflash,format=raw,unit=0,file="$CODE",readonly=on
        -drive if=pflash,format=raw,unit=1,file="$VARS"
        -chardev socket,id=ser0,path="$RUN/console.sock",server=on,wait=off,logfile="$RUN/serial.log"
        -serial chardev:ser0
        -monitor unix:"$RUN/monitor.sock",server,nowait
        -netdev user,id=n0,hostfwd=tcp::"$SSHPORT"-:22 -device virtio-net-pci,netdev=n0
        -display none -pidfile "$RUN/qemu.pid")
  [ -n "$CD" ] && args+=(-device ich9-ahci,id=ahci -drive file="$CD",media=cdrom,if=none,id=cd,readonly=on -device ide-cd,drive=cd,bus=ahci.0,bootindex=1)
  [ -n "$DISK" ] && args+=(-drive file="$DISK",if=none,id=hd0,format=qcow2 -device virtio-blk-pci,drive=hd0,bootindex=2)
  nohup setsid qemu-system-x86_64 "${args[@]}" </dev/null > "$RUN/qemu.log" 2>&1 &
  sleep 2
  pid_of >/dev/null || { echo "qemu did not start: $(tail -2 "$RUN/qemu.log")" >&2; exit 1; }
  echo "started $NAME pid $(pid_of) serial=$RUN/serial.log console=$RUN/console.sock monitor=$RUN/monitor.sock"
  ;;
*) echo "usage: uefi-vm.sh start|stop <name> ..." >&2; exit 2 ;;
esac
