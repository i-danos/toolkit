#!/bin/bash
# Boot a DANOS ISO under QEMU/KVM with a usable serial console.
#
# The ISO's isolinux default append is "boot=live components quiet splash" --
# no serial console -- and injecting console=ttyS0 at the boot: prompt means
# typing into a five-second window. Passing -kernel/-initrd with our own cmdline
# avoids that entirely; boot=live still finds /live/filesystem.squashfs on the
# attached CD.
#
# -cpu host is required: the default QEMU CPU model lacks SSE4.2/AVX and DPDK
# dies with SIGILL during dataplane startup.
#
# Set SEED=<path to a NoCloud seed.iso> to attach a second CD. Without one,
# ds-identify finds no datasource on a live boot and disables cloud-init, so the
# vrouter distro class and the DANOS modules never run and cannot be verified.
#
# Usage: boot-vm.sh <iso> [name] [ssh-port] [mem-mb]

set -u
ISO=${1:?usage: boot-vm.sh <iso> [name] [ssh-port] [mem-mb]}
NAME=${2:-danos}
SSHPORT=${3:-2222}
MEM=${4:-4096}

BIN=$(dirname "$ISO")/binary/live
RUN=${OBS_DIR:-/home/aikon/danos/.obs}/run/$NAME
mkdir -p "$RUN"

for f in vmlinuz initrd.img; do
  [ -f "$BIN/$f" ] || { echo "missing $BIN/$f -- run this against a freshly built tree" >&2; exit 1; }
done

# console=ttyS0 last so it becomes /dev/console; keep the boot messages (no
# "quiet") because a failure during live boot is exactly what we want to read.
# "cloud-init" on the cmdline is a DANOS convention, not decoration: the
# cloud-init units carry ConditionKernelCommandLine=cloud-init, and
# vyatta-install-image gates on "grep -q -w cloud-init /proc/cmdline" too.
# Without the token cloud-init is skipped, which is the intended default.
CMDLINE="boot=live components noeject nopersistence ${CI_TOKEN:-} console=tty0 console=ttyS0,115200n8"

echo "  name        $NAME"
echo "  iso         $(basename "$ISO")"
echo "  memory      ${MEM}M"
echo "  console     $RUN/console.sock  (unix socket)"
echo "  monitor     $RUN/monitor.sock"
echo "  ssh         localhost:$SSHPORT -> guest:22"
echo "  log         $RUN/console.log"

# net0 is management: user-mode networking with an SSH forward, and a virtio
# NIC so it stays on the kernel driver rather than being claimed by DPDK.
# net1/net2 are dataplane ports on isolated sockets for later topology work.
qemu-system-x86_64 \
  -name "$NAME" \
  -enable-kvm -cpu host -smp 2 -m "$MEM" \
  -kernel "$BIN/vmlinuz" -initrd "$BIN/initrd.img" -append "$CMDLINE" \
  -drive file="$ISO",media=cdrom,readonly=on \
  ${SEED:+-drive file="$SEED",media=cdrom,readonly=on} \
  -netdev user,id=net0,hostfwd=tcp::"$SSHPORT"-:22 \
  -device virtio-net-pci,netdev=net0 \
  -netdev socket,id=net1,listen=127.0.0.1:"$((SSHPORT + 1000))" \
  -device virtio-net-pci,netdev=net1 \
  -object rng-random,filename=/dev/urandom,id=rng0 \
  -device virtio-rng-pci,rng=rng0 \
  -display none \
  -serial unix:"$RUN/console.sock",server,nowait \
  -monitor unix:"$RUN/monitor.sock",server,nowait \
  -pidfile "$RUN/qemu.pid" \
  > "$RUN/qemu.log" 2>&1 &

echo "  pid         $!"
sleep 2
[ -S "$RUN/console.sock" ] && echo "  console socket up" || { echo "  console socket did not appear:"; cat "$RUN/qemu.log"; exit 1; }
