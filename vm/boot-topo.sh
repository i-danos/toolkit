#!/bin/bash
# Bring up a router topology for the DANOS test suites. TOPO selects which one;
# it defaults to fw, so a suite from another family needs it set explicitly.
#
#   TOPO=fw     FIREWALL                 three routers   (default)
#   TOPO=ipsec  IPSEC_VPN, MPLS_LDP      three routers
#   TOPO=bgp    BGP                      four routers
#
# The default is not a topology all three-router suites can use, and forgetting
# TOPO does not look like a wiring problem. The suite configures addresses on
# interfaces that are not there, the CLI accepts them, and the run fails as
# empty OSPF neighbour tables, 100% ping loss and a tunnel that never comes up
# -- product symptoms, all of them. IPSEC_VPN scored 5 of 10 that way, twice,
# once on a freshly booted topology, before the slots were compared against the
# suite's own test data.
#
# The default layout, TOPO=fw:
#
#   R1 (lo 1.1.1.1)            R2 firewall (lo 2.2.2.2)        R3 (lo 3.3.3.3)
#     dp0s8 10.1.1.2/24
#     dp0s9 65.1.1.2/24 <---> dp0s9  65.1.1.3/24
#                             dp0s10 66.1.1.3/24 <---> dp0s10 66.1.1.2/24
#                                                      dp0s9  172.16.1.2/24
#
# Interface names follow the PCI slot: -device ...,addr=0xN gives ensN, which
# the dataplane renames to dp0sN once it claims the port. Management therefore
# has to sit on a slot the suites do not use -- they want 3, 8, 9 and 10 -- so
# it goes on slot 31, which is what the test image's dataplane.conf excludes
# from DPDK.
#
# The inter-router links are QEMU socket netdevs. One side listens, the other
# connects, so the listeners must be started first; that is why R2 comes up
# before R1 and R3.
#
# Every NIC gets an explicit MAC of the form 52:54:00:<router>:<slot>:01.
# Without one QEMU derives the address from the PCI slot, so routers built the
# same way end up with identical MACs on a shared segment. That fails in a way
# that looks like a routing bug rather than a harness bug: OSPF hellos are
# multicast and still arrive, so the neighbour is discovered and appears in
# "show protocols ospf neighbor" -- but it sticks in ExStart, because the
# database exchange is unicast and needs ARP, and ping is 100% loss for the
# same reason.
#
# Usage: boot-topo.sh <test-iso>

set -u
ISO=${1:?usage: boot-topo.sh <test-iso>}
BIN=$(dirname "$ISO")/binary/live
RUNBASE=${OBS_DIR:-/home/aikon/danos/.obs}/run
MEM=${MEM:-3072}

[ -f "$BIN/vmlinuz" ] || { echo "missing $BIN/vmlinuz" >&2; exit 1; }

CMDLINE="boot=live components noeject nopersistence console=ttyS0,115200n8"

# Take down whatever is still running before booting anything.
#
# This script used to just start new VMs. It never stopped the old ones, and
# the consequences were invisible in exactly the wrong way: the previous
# topology's qemu still holds its pidfile lock, so the new one exits at once
# with
#
#   qemu-system-x86_64: cannot create PID file: Cannot lock pid file
#
# while the old VM keeps running, keeps answering on the same management port,
# and keeps the wiring of the topology *before* this one. The suite then
# configures dp0s10 on a router wired for a topology that has no dp0s10 and
# fails in the middle of a protocol test. That is what produced fw 6 of 16 and
# bgp 4 of 16 in a run whose every boot line said the topology was ready --
# three routers still on the ipsec wiring, one freshly booted for BGP, and 22
# failures that read as product defects.
#
# Kill by pidfile, never by pattern. "pkill -f qemu-system" has killed the
# shell driving the tests here, because that shell's own command line contains
# the pattern.
stop_all() {
  local d pid exe waited
  for d in "$RUNBASE"/*; do
    [ -f "$d/qemu.pid" ] || continue
    pid=$(cat "$d/qemu.pid" 2>/dev/null)
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    if tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q 'qemu-system'; then
      kill "$pid" 2>/dev/null
    fi
  done
  # Wait for the locks to be released. Starting before they are gives exactly
  # the failure above, just with a smaller window.
  for waited in $(seq 1 30); do
    local alive=0
    for d in "$RUNBASE"/*; do
      [ -f "$d/qemu.pid" ] || continue
      pid=$(cat "$d/qemu.pid" 2>/dev/null)
      case "$pid" in ''|*[!0-9]*) continue ;; esac
      if tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q 'qemu-system'; then
        alive=$((alive + 1))
      fi
    done
    [ "$alive" -eq 0 ] && break
    sleep 1
  done
  # Anything still up after thirty seconds is not going to shut down politely.
  for d in "$RUNBASE"/*; do
    [ -f "$d/qemu.pid" ] || continue
    pid=$(cat "$d/qemu.pid" 2>/dev/null)
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    if tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q 'qemu-system'; then
      kill -9 "$pid" 2>/dev/null; sleep 2
    fi
  done
  # Stale sockets outlive their VM and are what made a dead start look alive.
  for d in "$RUNBASE"/*; do
    rm -f "$d/console.sock" "$d/monitor.sock" "$d/qemu.pid" 2>/dev/null
  done
}

# link ports: R1<->R2 on 4165, R2<->R3 on 4166
start() {                      # name sshport mgmt-slot extra-args...
  local name=$1 sshport=$2; shift 2
  local run=$RUNBASE/$name
  local pid
  mkdir -p "$run"
  # Detach the VM from the short-lived boot-topo shell.  Without an explicit
  # session, a console/prep caller that closes its PTY can deliver SIGHUP to
  # the background QEMU exactly while prep-router reconnects for the admin
  # login, leaving a stale pid/socket pair and an empty qemu.log.
  nohup setsid qemu-system-x86_64 -name "$name" \
    -enable-kvm -cpu host -smp 2 -m "$MEM" \
    -kernel "$BIN/vmlinuz" -initrd "$BIN/initrd.img" -append "$CMDLINE" \
    -drive file="$ISO",media=cdrom,readonly=on \
    -netdev user,id=mgmt,hostfwd=tcp::"$sshport"-:22,hostfwd=tcp::"$((sshport + 200))"-:443 \
    -device virtio-net-pci,netdev=mgmt,addr=0x1f,mac="$MACBASE:1f:01" \
    "$@" \
    -display none \
    -serial unix:"$run/console.sock",server,nowait \
    -monitor unix:"$run/monitor.sock",server,nowait \
    -pidfile "$run/qemu.pid" \
    </dev/null > "$run/qemu.log" 2>&1 &
  pid=$!
  sleep 2
  # The check is on the process this call started, not on a socket file. A
  # socket left behind by the previous topology's VM satisfied "-S" perfectly
  # well, which is how a qemu that had already exited reported itself started.
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "  $name failed to start:"; sed 's/^/      /' "$run/qemu.log"; return 1
  fi
  if [ ! -S "$run/console.sock" ]; then
    echo "  $name started but has no console socket:"
    sed 's/^/      /' "$run/qemu.log"; return 1
  fi
  printf '  %-4s ssh=%s https=%s console=%s\n' "$name" "$sshport" "$((sshport + 200))" "$run/console.sock"
}

stop_all

# Each suite wires the routers differently, and the slot numbers come from its
# own test data. TOPO selects the layout:
#
#   fw     (FIREWALL)   R1.dp0s9 <-> R2.dp0s9 ; R2.dp0s10 <-> R3.dp0s10
#                       R1.dp0s8 = LAN        ; R3.dp0s9  = LAN
#   ipsec  (IPSEC_VPN,  R1.dp0s9 <-> R2.dp0s3 ; R2.dp0s8  <-> R3.dp0s8
#          MPLS_LDP)    R1.dp0s3 = LAN        ; R3.dp0s3  = LAN
#   bgp    (BGP)        four routers, five links -- see the case below
#
# The two ends of a link need not use the same slot; only the wiring matters.
TOPO=${TOPO:-fw}

case "$TOPO" in
fw)
  MACBASE=52:54:00:02 start r2 2232 \
    -netdev socket,id=l12,listen=127.0.0.1:4165 -device virtio-net-pci,netdev=l12,addr=0x9,mac=52:54:00:02:09:01 \
    -netdev socket,id=l23,listen=127.0.0.1:4166 -device virtio-net-pci,netdev=l23,addr=0xa,mac=52:54:00:02:0a:01
  sleep 3
  MACBASE=52:54:00:01 start r1 2231 \
    -netdev socket,id=l12,connect=127.0.0.1:4165 -device virtio-net-pci,netdev=l12,addr=0x9,mac=52:54:00:01:09:01 \
    -netdev user,id=lan1 -device virtio-net-pci,netdev=lan1,addr=0x8,mac=52:54:00:01:08:01
  MACBASE=52:54:00:03 start r3 2233 \
    -netdev socket,id=l23,connect=127.0.0.1:4166 -device virtio-net-pci,netdev=l23,addr=0xa,mac=52:54:00:03:0a:01 \
    -netdev user,id=lan2 -device virtio-net-pci,netdev=lan2,addr=0x9,mac=52:54:00:03:09:01
  echo
  echo "  expected: r1 ens31+dp0s8+dp0s9   r2 ens31+dp0s9+dp0s10   r3 ens31+dp0s9+dp0s10"
  ;;
ipsec)
  MACBASE=52:54:00:02 start r2 2232 \
    -netdev socket,id=l12,listen=127.0.0.1:4165 -device virtio-net-pci,netdev=l12,addr=0x3,mac=52:54:00:02:03:01 \
    -netdev socket,id=l23,listen=127.0.0.1:4166 -device virtio-net-pci,netdev=l23,addr=0x8,mac=52:54:00:02:08:01
  sleep 3
  MACBASE=52:54:00:01 start r1 2231 \
    -netdev socket,id=l12,connect=127.0.0.1:4165 -device virtio-net-pci,netdev=l12,addr=0x9,mac=52:54:00:01:09:01 \
    -netdev user,id=lan1 -device virtio-net-pci,netdev=lan1,addr=0x3,mac=52:54:00:01:03:01
  MACBASE=52:54:00:03 start r3 2233 \
    -netdev socket,id=l23,connect=127.0.0.1:4166 -device virtio-net-pci,netdev=l23,addr=0x8,mac=52:54:00:03:08:01 \
    -netdev user,id=lan2 -device virtio-net-pci,netdev=lan2,addr=0x3,mac=52:54:00:03:03:01
  echo
  echo "  expected: r1 ens31+dp0s3+dp0s9   r2 ens31+dp0s3+dp0s8   r3 ens31+dp0s3+dp0s8"
  ;;
bgp)
  # Four routers, five links. Listeners have to exist before the connecting
  # side starts, and R4 both listens (for R1 and R3) and connects (to R2), so
  # the order is R2, R4, then R1 and R3.
  #
  #   R1.dp0s3  <-> R2.dp0s3    201.1.1.0/24
  #   R2.dp0s9  <-> R3.dp0s9    202.1.1.0/24
  #   R2.dp0s10 <-> R4.dp0s10   203.1.1.0/24
  #   R3.dp0s3  <-> R4.dp0s3    204.1.1.0/24
  #   R1.dp0s9  <-> R4.dp0s9    205.1.1.0/24
  #
  # dp0sX in the suite's drawing is a literal placeholder, never resolved to a
  # slot and never configured, so the two LAN ports are left out.
  MACBASE=52:54:00:02 start r2 2232 \
    -netdev socket,id=a,listen=127.0.0.1:4165 -device virtio-net-pci,netdev=a,addr=0x3,mac=52:54:00:02:03:01 \
    -netdev socket,id=b,listen=127.0.0.1:4166 -device virtio-net-pci,netdev=b,addr=0x9,mac=52:54:00:02:09:01 \
    -netdev socket,id=c,listen=127.0.0.1:4167 -device virtio-net-pci,netdev=c,addr=0xa,mac=52:54:00:02:0a:01
  sleep 3
  MACBASE=52:54:00:04 start r4 2234 \
    -netdev socket,id=a,connect=127.0.0.1:4167 -device virtio-net-pci,netdev=a,addr=0xa,mac=52:54:00:04:0a:01 \
    -netdev socket,id=b,listen=127.0.0.1:4168 -device virtio-net-pci,netdev=b,addr=0x9,mac=52:54:00:04:09:01 \
    -netdev socket,id=c,listen=127.0.0.1:4169 -device virtio-net-pci,netdev=c,addr=0x3,mac=52:54:00:04:03:01
  sleep 3
  MACBASE=52:54:00:01 start r1 2231 \
    -netdev socket,id=a,connect=127.0.0.1:4165 -device virtio-net-pci,netdev=a,addr=0x3,mac=52:54:00:01:03:01 \
    -netdev socket,id=b,connect=127.0.0.1:4168 -device virtio-net-pci,netdev=b,addr=0x9,mac=52:54:00:01:09:01
  MACBASE=52:54:00:03 start r3 2233 \
    -netdev socket,id=a,connect=127.0.0.1:4166 -device virtio-net-pci,netdev=a,addr=0x9,mac=52:54:00:03:09:01 \
    -netdev socket,id=b,connect=127.0.0.1:4169 -device virtio-net-pci,netdev=b,addr=0x3,mac=52:54:00:03:03:01
  echo
  echo "  expected: r1 dp0s3+dp0s9  r2 dp0s3+dp0s9+dp0s10  r3 dp0s3+dp0s9  r4 dp0s3+dp0s9+dp0s10"
  ;;
*)
  echo "unknown TOPO=$TOPO (want fw, ipsec or bgp)" >&2; exit 1 ;;
esac
