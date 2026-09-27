#!/bin/bash
# The rest of P0.5 item 4 on an INSTALLED image: upgrade, select the new image,
# roll back, interface naming, cloud-init, and a boot with no network at all.
# accept-disk-install.sh covers install, disk boot and restart; this picks up
# from the disk it leaves behind.
#
# Nothing here writes to the disk it is given. Every boot runs on a throwaway
# qcow2 overlay backed by it, so the same installed disk can be reused, and a
# run that dies in the middle cannot damage it.
#
# The image being ADDED is the ISO itself, served over HTTP to the guest at
# 10.0.2.2 (QEMU's address for the host). Adding the image the disk was installed
# from is a valid upgrade: the installer neither knows nor cares, it fetches an
# ISO, checks its checksum, copies its squashfs under /boot/<name> and registers
# it with grub. It also means the added image's expected hash is known.
#
# The name typed at the installer's prompt is not always the name the image
# lands under (see DEFECTS.md, defect 14), so the new image's name is found by
# listing before and after, not assumed.
#
# Commands run over ssh as the admin account, which needs level superuser
# (accept-disk-install.sh sets it). Passwords go in on the first stdin line.
#
# UPG_ISO, if set, is the ISO that gets ADDED, so the upgrade can go between two
# different versions (the disk installed from an older ISO, UPG_ISO the newer).
# The default is the ISO itself. With UPG_ISO set the run also reads
# vyatta-image-tools' version inside each image it boots: the old image must say
# the old version, the new image a different one, and the rollback the old one
# again. EXPECT_BASE_VER / EXPECT_UPG_VER pin those versions if given. Set
# SKIP_BOOT_MODES=1 to stop after the naming check (no cloud-init or no-network).
#
# Usage: accept-lifecycle.sh <iso> <installed.qcow2> <outdir>
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ISO=${1:?usage: accept-lifecycle.sh <iso> <installed.qcow2> <outdir>}
BASE=${2:?installed disk}
OUT=${3:?outdir}
NAME=${NAME:-lc}
SSHPORT=${SSHPORT:-2297}
ISO_PORT=${ISO_PORT:-8331}
SEED=${SEED:-$HERE/../seed/seed.iso}
UPG_ISO=${UPG_ISO:-$ISO}
HOSTIP=${HOSTIP:-192.168.203.1}
PW=vyatta
IMG=upg1
RUN=${OBS_DIR:-/home/aikon/danos/.obs}/run/$NAME
GRUBPL=/opt/vyatta/sbin/vyatta_update_grub.pl
BOOT_TIMEOUT=${BOOT_TIMEOUT:-420}

[ -f "$ISO" ] && [ -f "$BASE" ] && [ -f "$UPG_ISO" ] || { echo "need an ISO and an installed disk" >&2; exit 1; }
[ -f "$SEED" ] || { echo "no NoCloud seed at $SEED" >&2; exit 1; }
# Every ssh in this script goes through the robot container. With it stopped (a
# host restart stops it) the first boot "did not reach ssh", which reads as a
# product failure and was once put down to memory pressure. Say what is wrong.
[ "$(docker inspect -f '{{.State.Running}}' danos-robot 2>/dev/null)" = true ] \
	|| { echo "BLOCKED: the danos-robot container is not running (docker start danos-robot)" >&2; exit 1; }
mkdir -p "$OUT" "$RUN"
exec > >(tee "$OUT/accept-lifecycle.log") 2>&1

rc=0
declare -a RESULTS
record() {
	RESULTS+=("$1|$2|$3")
	printf '  %-8s %s%s\n' "$2" "$1" "${3:+ -- $3}"
	case "$2" in FAIL|BLOCKED) rc=1 ;; esac
}

gssh() {
	docker exec danos-robot timeout ${T:-90} sshpass -p "$PW" ssh -p "$SSHPORT" \
	  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
	  "vyatta@$HOSTIP" "$1" 2>&1 | grep -v '^Welcome'
}
rootcmd() { gssh "echo $PW | sudo -S -p '' sh -c '$1'"; }
wait_ssh() {
	local deadline=$(( $(date +%s) + $1 ))
	while [ "$(date +%s)" -lt "$deadline" ]; do
		[ "$(T=20 gssh 'echo up' | tail -1)" = up ] && return 0
		sleep 8
	done
	return 1
}

qemu_pid() {
	local p; p=$(cat "$RUN/qemu.pid" 2>/dev/null)
	case "$p" in ''|*[!0-9]*) return 1 ;; esac
	tr '\0' ' ' </proc/$p/cmdline 2>/dev/null | grep -q -- "-name $NAME " || return 1
	echo "$p"
}
# A killed qemu can take minutes to exit on this host and holds the image lock
# and the ssh port until it does; wait for it, never a fixed sleep.
stop_vm() {
	local p; p=$(qemu_pid) || { rm -f "${RUN:?}"/*.sock "${RUN:?}/qemu.pid"; return 0; }
	kill "$p" 2>/dev/null
	for _ in $(seq 1 30); do kill -0 "$p" 2>/dev/null || break; sleep 1; done
	kill -9 "$p" 2>/dev/null
	while kill -0 "$p" 2>/dev/null; do sleep 1; done
	rm -f "${RUN:?}"/*.sock "${RUN:?}/qemu.pid"
}
SRV=""
cleanup() { stop_vm; [ -n "$SRV" ] && kill "$SRV" 2>/dev/null; }
trap cleanup EXIT

overlay() { rm -f "$1"; qemu-img create -q -f qcow2 -b "$BASE" -F qcow2 "$1"; }
boot() { DISK=$1 BOOT=disk "$HERE/boot-vm.sh" "$ISO" "$NAME" "$SSHPORT" 3072 >/dev/null 2>&1; }
reboot_guest() {
	rootcmd 'systemctl reboot' >/dev/null 2>&1
	sleep 25
	wait_ssh "$BOOT_TIMEOUT"
}
cmdline() { gssh 'cat /proc/cmdline' | tail -1; }
union_of() { printf '%s' "$1" | sed -n 's/.*vyatta-union=\([^ ]*\).*/\1/p'; }
images() { rootcmd "$GRUBPL --list-images" | tail -1; }
ver() { gssh "dpkg-query -W -f='\${Version}' vyatta-image-tools" | tail -1; }
CROSS=0; [ "$UPG_ISO" != "$ISO" ] && CROSS=1

echo "===== 0. A throwaway overlay of the installed disk ====="
OV=$OUT/lifecycle.qcow2
overlay "$OV" && record "overlay created; the installed disk is not written" PASS "$(basename "$BASE")" \
	|| { record "could not create the overlay" FAIL ""; exit 1; }

mkdir -p "$OUT/srv"; ln -sf "$UPG_ISO" "$OUT/srv/upg.iso"
python3 -m http.server "$ISO_PORT" --bind 127.0.0.1 --directory "$OUT/srv" >/dev/null 2>&1 &
SRV=$!
sleep 2
curl -sI "http://127.0.0.1:$ISO_PORT/upg.iso" | head -1 | grep -q 200 \
	|| { record "the ISO is not being served" BLOCKED "port $ISO_PORT"; exit 1; }

echo
echo "===== 1. Baseline ====="
stop_vm
boot "$OV"
wait_ssh "$BOOT_TIMEOUT" || { record "the installed disk did not boot to ssh" BLOCKED ""; exit 1; }
CMD0=$(cmdline); UN0=$(union_of "$CMD0")
NIC0=$(gssh 'cat /sys/class/net/dp0s3/address' | tail -1)
IM0=$(images)
V0=$(ver)
echo "    version ${V0:-unreadable}  (vyatta-image-tools in the running image)"
echo "    union   ${UN0:-none}"
echo "    dp0s3   ${NIC0:-unreadable}"
echo "    images  ${IM0:-none}"
[ -n "$UN0" ] && [ -n "$IM0" ] && [ -n "$NIC0" ] \
	&& record "baseline read" PASS "" || { record "baseline unreadable" BLOCKED ""; exit 1; }
ORIG=${UN0##*/}
if [ "$CROSS" = 1 ]; then
	if [ -n "${EXPECT_BASE_VER:-}" ]; then
		[ "$V0" = "$EXPECT_BASE_VER" ] && record "the installed image is the old version" PASS "$V0" \
			|| { record "the installed image is not the expected old version" BLOCKED "wanted $EXPECT_BASE_VER, got ${V0:-unreadable}"; exit 1; }
	else
		record "old image version read" PASS "${V0:-unreadable}"
	fi
fi

echo
echo "===== 2. Upgrade: add an image over http ====="
INSTALL="{ echo $PW; printf '$IMG\\nYes\\nYes\\nYes\\nYes\\nYes\\n'; } | sudo -S -p '' /opt/vyatta/sbin/vyatta-install-image http://10.0.2.2:$ISO_PORT/upg.iso 2>&1 | tail -4"
T=900 gssh "$INSTALL" | sed 's/^/    /'
IM1=$(images)
echo "    images  ${IM1:-none}"
NEW=$(printf '%s' "$IM1" | tr ',' '\n' | grep -vx "$ORIG" | grep . | head -1)
[ -n "$NEW" ] && record "a second image is registered" PASS "$NEW" \
	|| { record "no second image after the upgrade" FAIL "before: $IM0  after: $IM1"; exit 1; }
DIRS=$(rootcmd 'ls /run/live/persistence/vda2/boot' | tr '\n' ' ')
case " $DIRS " in *" $NEW "*) record "the new image's files are on disk" PASS "/boot/$NEW" ;; \
	*) record "the new image's files are not on disk" FAIL "$DIRS" ;; esac

echo
echo "===== 3. Select the new image and boot it ====="
rootcmd "$GRUBPL --set-default-boot-index=$NEW" >/dev/null 2>&1
reboot_guest || { record "no ssh after rebooting into the new image" FAIL ""; exit 1; }
CMD1=$(cmdline); UN1=$(union_of "$CMD1")
NIC1=$(gssh 'cat /sys/class/net/dp0s3/address' | tail -1)
echo "    union   ${UN1:-none}"
[ "$UN1" = "/boot/$NEW" ] && record "it booted the new image" PASS "$UN1" \
	|| record "it did not boot the new image" FAIL "wanted /boot/$NEW, got ${UN1:-none}"
[ "$(gssh 'id -un' | tail -1)" = vyatta ] && record "the admin account survived the switch" PASS "" \
	|| record "the admin account is gone" FAIL ""
if [ "$CROSS" = 1 ]; then
	V1=$(ver); echo "    version ${V1:-unreadable}"
	if [ -n "${EXPECT_UPG_VER:-}" ]; then
		[ "$V1" = "$EXPECT_UPG_VER" ] && record "the new image runs the new version" PASS "$V0 -> $V1" \
			|| record "the new image does not run the expected version" FAIL "wanted $EXPECT_UPG_VER, got ${V1:-unreadable}"
	else
		[ -n "$V1" ] && [ "$V1" != "$V0" ] && record "the new image runs a different version" PASS "$V0 -> $V1" \
			|| record "the new image runs the same version as the old" FAIL "$V0 -> ${V1:-unreadable}"
	fi
fi

echo
echo "===== 4. Roll back to the original ====="
rootcmd "$GRUBPL --set-default-boot-index=$ORIG" >/dev/null 2>&1
reboot_guest || { record "no ssh after rolling back" FAIL ""; exit 1; }
CMD2=$(cmdline); UN2=$(union_of "$CMD2")
NIC2=$(gssh 'cat /sys/class/net/dp0s3/address' | tail -1)
echo "    union   ${UN2:-none}"
[ "$UN2" = "/boot/$ORIG" ] && record "it booted the original image again" PASS "$UN2" \
	|| record "rollback did not land on the original" FAIL "wanted /boot/$ORIG, got ${UN2:-none}"
[ "$(gssh 'id -un' | tail -1)" = vyatta ] && record "the admin account survived the rollback" PASS "" \
	|| record "the admin account is gone after rollback" FAIL ""
if [ "$CROSS" = 1 ]; then
	V2=$(ver); echo "    version ${V2:-unreadable}"
	[ -n "$V2" ] && [ "$V2" = "$V0" ] && record "the rollback runs the old version again" PASS "$V2" \
		|| record "the rollback does not run the old version" FAIL "wanted $V0, got ${V2:-unreadable}"
fi

echo
echo "===== 5. Interface naming across three boots ====="
echo "    dp0s3   $NIC0   $NIC1   $NIC2"
[ -n "$NIC0" ] && [ "$NIC0" = "$NIC1" ] && [ "$NIC1" = "$NIC2" ] \
	&& record "dp0s3 keeps its name and MAC across the image switches" PASS "$NIC0" \
	|| record "dp0s3 changed across boots" FAIL "$NIC0 $NIC1 $NIC2"

if [ "${SKIP_BOOT_MODES:-0}" != 1 ]; then
echo
echo "===== 6. cloud-init with a NoCloud seed ====="
# A live boot with the "cloud-init" kernel token, not the installed disk: the
# cloud-init units carry ConditionKernelCommandLine=cloud-init, an installed
# disk boots from grub without that token by design (and the installer refuses to
# run with it), so on the installed disk cloud-init never starts and the hostname
# stays "node". Booting the installed disk with a seed and calling that a
# cloud-init failure was this script's first mistake. This is what the earlier
# cloud-init evidence exercised too. Note that boot-vm.sh takes the live kernel
# and initrd from the build tree next to the ISO.
stop_vm
t0=$(date +%s)
CI_TOKEN=cloud-init SEED="$SEED" "$HERE/boot-vm.sh" "$ISO" "$NAME" "$SSHPORT" 3072 >/dev/null 2>&1
got=""
for _ in $(seq 1 40); do
	out=$(timeout 150 "$HERE/console.py" "$RUN/console.sock" tmpuser tmppwd 'hostname' 2>&1 | tr -d '\r')
	printf '%s\n' "$out" | grep -q "login incorrect" && break
	printf '%s\n' "$out" | grep -qx 'danos-ci-test' && { got=danos-ci-test; break; }
	printf '%s\n' "$out" | grep -qx 'node' && { got=node; break; }
	sleep 5
done
secs=$(( $(date +%s) - t0 ))
echo "    hostname ${got:-unreadable}   (login after ${secs}s)"
[ "$got" = "danos-ci-test" ] && record "the seed's hostname was applied, no stall" PASS "${secs}s to a login" \
	|| record "the seed's hostname was not applied" FAIL "${got:-no login} after ${secs}s"

echo
echo "===== 7. Boot with no network at all ====="
stop_vm
overlay "$OV"
# Zero NICs, not a NIC with the cable pulled: that is a different, weaker
# condition. boot-vm.sh always adds two. QEMU also adds a default NIC of its own
# unless told not to, so "-nic none" is what actually removes it; leaving
# -netdev off alone would still give the guest a network.
qemu-system-x86_64 -name "$NAME" -enable-kvm -cpu host -smp 2 -m 3072 \
  -nic none -boot order=c \
  -drive file="$OV",if=virtio,format=qcow2 \
  -drive file="$ISO",media=cdrom,readonly=on \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0 \
  -display none \
  -serial unix:"$RUN/console.sock",server,nowait \
  -monitor unix:"$RUN/monitor.sock",server,nowait \
  -pidfile "$RUN/qemu.pid" > "$RUN/qemu.log" 2>&1 &
sleep 3
qc=$(tr '\0' ' ' </proc/$(cat "$RUN/qemu.pid" 2>/dev/null)/cmdline 2>/dev/null)
case "$qc" in
	*-netdev*|*-net\ *) record "the machine was given a network, so this is not the no-network case" BLOCKED "" ;;
	*"-nic none"*) record "the machine was started with -nic none and no -netdev" PASS "" ;;
	*) record "could not read the machine's command line" BLOCKED "" ;;
esac
# The console echoes a carriage return in front of every output line, so a
# whole-line match on the output has to strip it first. Markers are matched, not
# bare words: the echoed command line contains the marker text too.
t0=$(date +%s); got=""
for _ in $(seq 1 60); do
	out=$(timeout 150 "$HERE/console.py" "$RUN/console.sock" vyatta "$PW" \
	  'echo WHO=$(id -un)' 'echo NDEV=$(ls -d /sys/class/net/*/device 2>/dev/null | wc -l)' 2>&1 | tr -d '\r')
	printf '%s\n' "$out" | grep -qx 'WHO=vyatta' && { got=yes; break; }
	sleep 5
done
secs=$(( $(date +%s) - t0 ))
[ -n "$got" ] && record "a login works with no network at all" PASS "${secs}s" \
	|| record "no usable login with no network" FAIL "after ${secs}s"
if [ -n "$got" ]; then
	# Virtual interfaces (lo, pimreg, pim6reg) exist with no NIC; a NIC has a
	# /sys/class/net/<if>/device link. None may.
	if printf '%s\n' "$out" | grep -qx 'NDEV=0'; then
		record "the guest has no network device" PASS "only virtual interfaces"
	else
		record "the guest sees a network device" FAIL "$(printf '%s\n' "$out" | grep -x 'NDEV=[0-9]*' | tail -1)"
	fi
fi
fi

echo
echo "===== Result ====="
printf '%s\n' "${RESULTS[@]}" | awk -F'|' '{printf "  %-8s %s\n", $2, $1}'
pass=$(printf '%s\n' "${RESULTS[@]}" | grep -c '|PASS|')
tot=${#RESULTS[@]}
printf '  %s of %s\n' "$pass" "$tot"

python3 - "$OUT/lifecycle-result.json" "$ISO" "$pass" "$tot" <<'PY' "${RESULTS[@]}"
import json, sys, datetime
out, iso, npass, ntot = sys.argv[1:5]
rows = []
for r in sys.argv[5:]:
    name, status, detail = (r.split("|", 2) + ["", ""])[:3]
    rows.append({"check": name, "status": status, "detail": detail})
json.dump({
    "schema_version": 1, "read_only": False,
    "gate": "P0.5-4 upgrade, rollback, naming, cloud-init, no-network",
    "image": iso.rsplit("/", 1)[-1],
    "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "passed": int(npass), "total": int(ntot),
    "status": "PASS" if int(npass) == int(ntot) else "INCOMPLETE",
    "checks": rows,
}, open(out, "w"), indent=2)
print("  evidence: " + out)
PY
exit $rc
