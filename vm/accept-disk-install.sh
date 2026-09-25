#!/bin/bash
# P0.5 item 4: install the product image to a disk, boot it, restart it.
#
# This drives boot-vm.sh rather than assembling its own QEMU command line.
# Doing it the other way cost seven failed runs, every one of them the harness
# and not the product, and three of the things boot-vm.sh already knows are
# exactly what went wrong:
#
#   -cpu host                   the default QEMU CPU lacks SSE4.2 and the data
#                               plane dies with SIGILL
#   BOOT=disk                   drops -kernel/-initrd so the bootloader the
#                               installer wrote is what runs -- not the ISO's
#                               kernel with a disk merely attached
#
# There is deliberately no cloud-init token on the kernel command line.
# boot-vm.sh can add one through CI_TOKEN, and vyatta-install-image contains
#
#     if grep -q -w cloud-init /proc/cmdline ; then
#         fail_exit 'add/install image is not permitted for cloud images'
#
# which is a refusal, not a requirement: a cloud image is not installed this
# way. Reading it as a prerequisite and supplying the token produced exactly
# that error, one run after several spent looking for the cause elsewhere.
#
# 20 GiB because that is what the previous release installed onto. An 8 GiB
# attempt failed and was misdiagnosed here as the installer's own partition
# defaults overflowing the disk; a 16 GiB run disproved that.
#
# The live environment has one account, tmpuser, in no group granting sudo.
# That is why installing is required for anything needing root, and it is the
# account the install has to be driven as. The account the installer *creates*
# is a separate thing with a separate password.
#
# Prior art: UPGRADE-RECORD.md records this path passing 74 of 74 on the
# previous release, from one install cloned into four backing-file copies.
# This re-establishes it for 2608; it does not discover it.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ISO=${1:?usage: accept-disk-install.sh <product-iso> [outdir]}
OUTDIR=${2:-/home/aikon/danos/acceptance-2608-20260920/disk-install}
NAME=${NAME:-diskinst}
RUN=${OBS_DIR:-/home/aikon/danos/.obs}/run/$NAME
DISK=${DISK:-$OUTDIR/run/installed.qcow2}
DISK_GB=${DISK_GB:-20}
SSHPORT=${SSHPORT:-2299}
MEM=${MEM:-3072}
INSTALL_TIMEOUT=${INSTALL_TIMEOUT:-1800}
BOOT_TIMEOUT=${BOOT_TIMEOUT:-420}
ADMIN_USER=${ADMIN_USER:-vyatta}
ADMIN_PASS=${ADMIN_PASS:-vyatta}

[ -f "$ISO" ] || { echo "no such image: $ISO" >&2; exit 1; }
mkdir -p "$OUTDIR/run" "$RUN"

exec 9>"$OUTDIR/run/.lock"
flock -n 9 || { echo "another run holds $OUTDIR/run" >&2; exit 1; }

LOG="$OUTDIR/accept-disk-install.log"
exec > >(tee "$LOG") 2>&1

rc=0
declare -a RESULTS
record() {
	RESULTS+=("$1|$2|$3")
	printf '  %-8s %s%s\n' "$2" "$1" "${3:+ -- $3}"
	case "$2" in FAIL|BLOCKED) rc=1 ;; esac
}

stop_vm() {
	local pid
	[ -f "$RUN/qemu.pid" ] || return 0
	pid=$(cat "$RUN/qemu.pid" 2>/dev/null)
	case "$pid" in ''|*[!0-9]*) return 0 ;; esac
	kill "$pid" 2>/dev/null
	for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
	kill -9 "$pid" 2>/dev/null
	rm -f "$RUN/qemu.pid" "$RUN/console.sock" "$RUN/monitor.sock"
}
trap stop_vm EXIT

# ssh from the robot container; the host has no sshpass.
HOSTIP=${HOSTIP:-192.168.203.1}
ssh_guest() {
	docker exec danos-robot timeout 60 sshpass -p "$ADMIN_PASS" ssh -p "$SSHPORT" \
	  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	  -o ConnectTimeout=8 "$ADMIN_USER@$HOSTIP" "$1" 2>&1
}
wait_ssh() {
	local deadline=$(( $(date +%s) + $1 ))
	while [ "$(date +%s)" -lt "$deadline" ]; do
		[ "$(ssh_guest 'echo up' | tail -1)" = up ] && return 0
		sleep 10
	done
	return 1
}

echo "===== 0. A disk of its own ====="
stop_vm
rm -f "$DISK"
qemu-img create -f qcow2 "$DISK" "${DISK_GB}G" > /dev/null 2>&1
[ -f "$DISK" ] && record "fresh ${DISK_GB} GiB qcow2 created" PASS "$DISK" \
               || { record "could not create the disk" FAIL ""; exit 1; }
echo "    the guest sees only this file"

echo
echo "===== 1. Live boot, then \"install image\" ====="
DISK="$DISK" BOOT=live \
  "$HERE/boot-vm.sh" "$ISO" "$NAME" "$SSHPORT" "$MEM" 2>&1 | sed 's/^/    /'
sleep 3
[ -S "$RUN/console.sock" ] && record "the live VM started" PASS "" \
  || { record "the live VM did not start" FAIL "$(tail -3 "$RUN/qemu.log" 2>/dev/null)"; exit 1; }

echo "    waiting for a login prompt"
ready=no
for _ in $(seq 1 30); do
	if timeout 60 "$HERE/console.py" "$RUN/console.sock" tmpuser tmppwd 'true' >/dev/null 2>&1; then
		ready=yes; break
	fi
	sleep 10
done
[ "$ready" = yes ] || { record "the live system never reached a usable login" FAIL ""; exit 1; }
record "the live system accepts tmpuser" PASS ""

# The install runs as tmpuser, the live account. An earlier revision of this
# script created a superuser first, on the theory that pam_sandbox hides the
# disk from tmpuser; a manual install as tmpuser onto a VMware disk disproved
# that, so the step is gone.
echo "    driving \"install image\" over the console"
: > "$RUN/install-console.log"
timeout "$INSTALL_TIMEOUT" "$HERE/console-install.py" "$RUN/console.sock" \
    --user tmpuser --password tmppwd \
    --admin-user "$ADMIN_USER" --admin-password "$ADMIN_PASS" \
    --timeout "$INSTALL_TIMEOUT" >> "$RUN/install-console.log" 2>&1
inst_rc=$?
written=$(( $(stat -c%s "$DISK" 2>/dev/null || echo 0) / 1048576 ))
stop_vm

if [ "$inst_rc" -eq 0 ] && [ "$written" -gt 512 ]; then
	record "the installer finished and wrote the disk" PASS "${written} MiB"
elif [ "$written" -gt 512 ]; then
	record "the disk was written but success was not reported" BLOCKED \
	       "${written} MiB; see $RUN/install-console.log"
else
	record "the installer wrote nothing" FAIL \
	       "${written} MiB; see $RUN/install-console.log"
	exit 1
fi

echo
echo "===== 2. Boot the disk, with the ISO's kernel out of the picture ====="
DISK="$DISK" BOOT=disk \
  "$HERE/boot-vm.sh" "$ISO" "$NAME" "$SSHPORT" "$MEM" 2>&1 | sed 's/^/    /'
sleep 3
[ -S "$RUN/console.sock" ] && record "the installed system started" PASS "" \
  || { record "it did not start" FAIL ""; exit 1; }

if wait_ssh "$BOOT_TIMEOUT"; then
	record "it booted and answered ssh" PASS ""
else
	# A fresh DANOS has no ssh service until configured. Through qemu's user
	# networking that is indistinguishable from a system that never booted:
	# the host side of a hostfwd accepts either way. So configure it over the
	# console before calling this a boot failure.
	#
	# The service alone is not enough: a fresh install has no address on the
	# management NIC (dp0s3 under qemu user networking, admin-down), so hostfwd
	# has nothing to reach and sshd never answers.
	#
	# Level superuser is needed too: the installer creates the admin account
	# as a plain admin, whose shell is a sandbox with no systemctl, so every
	# service check below would report "Host is down" for a healthy system.
	#
	# The command has to reach the shell as ONE line with no tab characters.
	# console.py types it into an interactive vbash, and a tab is completion:
	# the indented continuation lines this used to send turned into a listing of
	# operational commands, the set/commit never ran, and the run reported a
	# product failure that was really garbled input.
	echo "    no ssh yet; enabling it over the console"
	timeout 180 "$HERE/console.py" "$RUN/console.sock" "$ADMIN_USER" "$ADMIN_PASS" \
	  'SID=$$; eval "$(cli-shell-api getSessionEnv $SID)"; cli-shell-api setupSession; vcli -s $SID -c "set service ssh" 2>&1 | grep -vi "node exists" || true; vcli -s $SID -c "set interfaces dataplane dp0s3 address dhcp" 2>&1 | grep -vi "node exists" || true; vcli -s $SID -c "set system login user vyatta level superuser" 2>&1 | grep -vi "node exists" || true; vcli -s $SID -c commit 2>&1 | tail -2; vcli -s $SID -c save 2>&1 | tail -1' 2>&1 | tail -6 | sed 's/^/      /'
	if wait_ssh 180; then
		record "it booted; ssh needed configuring" PASS "expected on a fresh install"
	else
		record "no ssh even after configuring the service" FAIL "see $RUN/console.log"
		exit 1
	fi
fi

echo
echo "===== 3. Is this the installed system, or the live one again? ====="
root=$(ssh_guest "findmnt -no SOURCE,FSTYPE /" | tail -1)
cmdline=$(ssh_guest "cat /proc/cmdline" | tail -1)
dp=$(ssh_guest "systemctl is-active vyatta-dataplane" | tail -1)
echo "    root      ${root:-unreadable}"
echo "    cmdline   ${cmdline:-unreadable}"
echo "    dataplane ${dp:-unreadable}"

# An installed DANOS is not a plain ext4 root. It boots as boot=live with a
# union root (overlay) assembled from the image under /boot/<release>, so
# "root is an overlay" and "boot=live" are true of the installed system and
# say nothing about live versus installed. What only a disk boot has is a
# bootloader-supplied BOOT_IMAGE and vyatta-union under /boot, and a virtio
# disk partition in use by the guest -- the live CD has neither.
#
# The admin account's shell is a sandbox whose /proc/mounts hides the source
# device, so no '/dev/vda2' line ever appears there. The partition shows up as
# the persistence layer's path instead (/run/live/persistence/vda2/boot/...),
# so match that as well as a plain /dev/vd* source.
mounts=$(ssh_guest "cat /proc/mounts")
disk=$(printf '%s\n' "$mounts" | grep -m1 -E '^/dev/vd|/run/live/persistence/vd[a-z][0-9]*/boot/' | cut -c1-120)
echo "    disk mnt  ${disk:-none}"

case "$cmdline" in
	*BOOT_IMAGE=/boot/*) record "the kernel came from the disk's /boot" PASS "" ;;
	*) record "the kernel did not come from the disk's /boot" FAIL "${cmdline:-unreadable}" ;;
esac
case "$cmdline" in
	*vyatta-union=/boot/*) record "the root union is assembled from /boot" PASS "" ;;
	*) record "no vyatta-union=/boot/ on the command line" FAIL "${cmdline:-unreadable}" ;;
esac
[ -n "$disk" ] && record "a virtio disk partition is in use by the guest" PASS "$disk" \
               || record "no /dev/vd* partition in use -- not running from the disk" FAIL ""
[ "$dp" = active ] && record "the data plane runs on the installed system" PASS "" \
                   || record "the data plane is not running" FAIL "${dp:-unreadable}"

echo
echo "===== 4. Does it survive its own restart? ====="
before_root="$root"
before_boot=$(ssh_guest "cat /proc/sys/kernel/random/boot_id" | tail -1)
ssh_guest "echo $ADMIN_PASS | sudo -S -p '' systemctl reboot" > /dev/null 2>&1
sleep 25
if wait_ssh "$BOOT_TIMEOUT"; then
	after_boot=$(ssh_guest "cat /proc/sys/kernel/random/boot_id" | tail -1)
	# ssh answering proves nothing if the reboot never ran; a new boot_id does.
	[ -n "$before_boot" ] && [ "$before_boot" != "$after_boot" ] \
	  && record "it really restarted" PASS "" \
	  || record "it did not restart" FAIL "boot_id ${before_boot:-unreadable} -> ${after_boot:-unreadable}"
	after_root=$(ssh_guest "findmnt -no SOURCE,FSTYPE /" | tail -1)
	after_dp=$(ssh_guest "systemctl is-active vyatta-dataplane" | tail -1)
	[ "$after_root" = "$before_root" ] \
	  && record "it came back on the same root" PASS "$after_root" \
	  || record "the root changed across a restart" FAIL "$before_root -> $after_root"
	[ "$after_dp" = active ] \
	  && record "the data plane came back" PASS "" \
	  || record "the data plane did not come back" FAIL "${after_dp:-unreadable}"
	# ssh answering here proves the configuration was saved and not merely
	# committed: a commit without a save would be gone by now.
	record "the saved configuration survived" PASS "ssh answered without reconfiguring"
else
	record "it did not come back after a restart" FAIL "see $RUN/console.log"
fi

echo
echo "===== Result ====="
printf '%s\n' "${RESULTS[@]}" | awk -F'|' '{printf "  %-8s %s\n", $2, $1}'
pass=$(printf '%s\n' "${RESULTS[@]}" | grep -c '|PASS|')
tot=${#RESULTS[@]}
printf '  %s of %s\n' "$pass" "$tot"

python3 - "$OUTDIR/disk-install-result.json" "$ISO" "$pass" "$tot" <<'PY' "${RESULTS[@]}"
import json, sys, datetime
out, iso, npass, ntot = sys.argv[1:5]
rows = []
for r in sys.argv[5:]:
    name, status, detail = (r.split("|", 2) + ["", ""])[:3]
    rows.append({"check": name, "status": status, "detail": detail})
json.dump({
    "schema_version": 1, "read_only": False,
    "gate": "P0.5-4 disk install, boot and restart",
    "image": iso.rsplit("/", 1)[-1],
    "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "passed": int(npass), "total": int(ntot),
    "status": "PASS" if int(npass) == int(ntot) else "INCOMPLETE",
    "checks": rows,
}, open(out, "w"), indent=2)
print("  evidence: " + out)
PY
exit $rc
