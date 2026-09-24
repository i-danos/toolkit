#!/bin/bash
# P2, the two cases verify-power-loss.sh left open: a power cut *during boot*
# and a power cut *during `add system image`*.
#
#   MODE=boot     SIGKILL qemu N seconds after it starts, before the guest has
#                 finished coming up, then boot again. Every cut lands in a
#                 different phase: firmware, kernel, initramfs and overlay
#                 mount, systemd. The disk is barely written during boot, so
#                 this is expected to be uneventful -- it is here because
#                 "expected to be uneventful" is not a measurement.
#   MODE=upgrade  SIGKILL qemu at fractions of a measured, uninterrupted
#                 `vyatta-install-image` run. This is the dangerous one. The
#                 installer writes a second image under /boot/<name>/ and then
#                 edits the shared grub.cfg so the new image is the DEFAULT.
#                 If grub.cfg is written before the image is complete, a cut
#                 in between leaves a machine whose next boot loads a
#                 half-copied squashfs.
#
# After each cut and reboot the guest is asked what is on disk and whether
# every image grub can boot exists in full (imgcheck.py). In upgrade mode a
# machine that came back on the old image must also be able to finish the job:
# the same installer is run again and the result checked.
#
# Same limits as verify-power-loss.sh: SIGKILL of qemu is a power cut as the
# guest sees it, not a host power failure.
#
# Usage: MODE=boot|upgrade verify-power-loss-more.sh <iso> <base.qcow2> <outdir>
#   boot:    DELAYS="5 10 15 ..."        seconds after qemu starts
#   upgrade: FRACTIONS="0.5 0.6 ..."     of the control's install time
# The ISO is served to the guest from http://10.0.2.2:$ISO_PORT/upg.iso, which
# the caller starts; this script only checks that it answers.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ISO=${1:?usage: MODE=boot|upgrade verify-power-loss-more.sh <iso> <base.qcow2> <outdir>}
BASE=${2:?base disk}
OUT=${3:?outdir}
MODE=${MODE:?set MODE=boot or MODE=upgrade}
NAME=plr
SSHPORT=${SSHPORT:-2298}
ISO_PORT=${ISO_PORT:-8330}
RUN=${OBS_DIR:-/home/aikon/danos/.obs}/run/$NAME
PW=vyatta
IMG=upg1
mkdir -p "$OUT" "$RUN"
exec > >(tee "$OUT/power-loss-$MODE.log") 2>&1

gssh() {
  docker exec danos-robot timeout ${T:-90} sshpass -p "$PW" ssh -p "$SSHPORT" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
    vyatta@192.168.203.1 "$1" 2>&1 | grep -v '^Welcome'
}
wait_ssh() {
  local deadline=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(T=20 gssh 'echo up' | tail -1)" = up ] && return 0
    sleep 6
  done
  return 1
}
qemu_pid() {
  local p; p=$(cat "$RUN/qemu.pid" 2>/dev/null)
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  tr '\0' ' ' </proc/$p/cmdline 2>/dev/null | grep -q -- "-name $NAME " || return 1
  echo "$p"
}
# A SIGKILLed qemu on this host has taken 0.2s to 432s to exit and holds the
# image's write lock and the ssh port until it does.
wait_gone() {
  local p=$1 t0; t0=$(date +%s)
  while kill -0 "$p" 2>/dev/null; do sleep 0.5; done
  local dt=$(( $(date +%s) - t0 )); [ "$dt" -ge 3 ] && echo "  (qemu $p took ${dt}s to exit)"
  return 0
}
stop_vm() {
  local p; p=$(qemu_pid) || { rm -f "${RUN:?}"/*.sock "${RUN:?}/qemu.pid"; return 0; }
  kill "$p" 2>/dev/null
  for _ in $(seq 1 30); do kill -0 "$p" 2>/dev/null || break; sleep 1; done
  kill -9 "$p" 2>/dev/null
  wait_gone "$p"
  rm -f "${RUN:?}"/*.sock "${RUN:?}/qemu.pid"
}
trap stop_vm EXIT
boot() { DISK=$1 BOOT=disk "$HERE/boot-vm.sh" "$ISO" "$NAME" "$SSHPORT" 3072 >/dev/null 2>&1; }
console_screen() {
  python3 - "$RUN/console.sock" <<'PY'
import socket, sys, time
try:
    s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.settimeout(3)
    s.sendall(b"\r"); time.sleep(2); buf = b""; end = time.time() + 8
    while time.time() < end:
        try: d = s.recv(4096)
        except socket.timeout: break
        if not d: break
        buf += d
    print(repr(buf.decode(errors="replace")[-300:]) if buf else "(silent)")
except Exception as e:
    print("(console unreachable: %s)" % e)
PY
}
# Passwords go in on the first stdin line; whatever follows reaches the command.
rootcmd() { gssh "echo $PW | sudo -S -p '' sh -c '$1'"; }
inspect() {
  T=120 rootcmd 'sha=$(sha256sum /config/config.boot | cut -c1-16)
    live=$(vtysh -c "show ip route static" 2>/dev/null | grep -c "10\.[0-9]*\.0\.0/24")
    act=$(systemctl is-active configd vyatta-dataplane frr | tr "\n" ",")
    failed=$(systemctl --failed --no-legend | wc -l)
    rw=$(touch /config/.wtest 2>/dev/null && echo rw && rm -f /config/.wtest || echo RO)
    echo sha=$sha active=$act failed=$failed fs=$rw' | tail -1
}
push_checker() {
  docker cp "$HERE/imgcheck.py" danos-robot:/tmp/imgcheck.py >/dev/null 2>&1
  docker exec danos-robot sh -c "sshpass -p $PW scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P $SSHPORT /tmp/imgcheck.py vyatta@192.168.203.1:/tmp/" >/dev/null 2>&1
}
imgcheck() { T=240 rootcmd "python3 /tmp/imgcheck.py $EXP_ARGS" | tail -1; }
# The installer's prompts (image name, then save-config and ssh-keys, plus
# "replace it?" on a retry) all take Yes; the name is the one answer that matters.
INSTALL="{ echo $PW; printf '$IMG\\nYes\\nYes\\nYes\\nYes\\nYes\\n'; } | sudo -S -p '' /opt/vyatta/sbin/vyatta-install-image http://10.0.2.2:$ISO_PORT/upg.iso 2>&1 | tail -3"
kv() { echo "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -1; }

curl -sI "http://127.0.0.1:$ISO_PORT/upg.iso" | head -1 | grep -q 200 || { echo "BLOCKED: nothing serves the iso on :$ISO_PORT"; exit 1; }

echo "===== base ($MODE) ====="
stop_vm
ov=$OUT/control.qcow2; rm -f "$ov"; qemu-img create -q -f qcow2 -b "$BASE" -F qcow2 "$ov"
boot "$ov"; t0=$(date +%s)
wait_ssh 400 || { echo "BLOCKED: base does not boot to ssh"; exit 1; }
BOOT_S=$(( $(date +%s) - t0 )); echo "base reached ssh after ${BOOT_S}s"
push_checker
OLD=$(inspect); echo "old  $OLD"; OLDSHA=$(kv "$OLD" sha)
EXP_SIZE=$(rootcmd 'stat -c%s /run/live/persistence/vda2/boot/2608/2608.squashfs' | tail -1)
EXP_SHA=$(rootcmd 'sha256sum /run/live/persistence/vda2/boot/2608/2608.squashfs' | cut -c1-16 | tail -1)
echo "reference squashfs: size=$EXP_SIZE sha=$EXP_SHA"
# The image being added may come from a different ISO than the one installed, so
# its expected squashfs is measured from that ISO's own file when given.
EXP_ARGS="2608=$EXP_SIZE:$EXP_SHA"
if [ -n "${UPG_SQUASHFS:-}" ]; then
  UPG_SIZE=$(stat -c%s "$UPG_SQUASHFS"); UPG_SHA=$(sha256sum "$UPG_SQUASHFS" | cut -c1-16)
  EXP_ARGS="$EXP_ARGS $IMG=$UPG_SIZE:$UPG_SHA"
  echo "upgrade squashfs: size=$UPG_SIZE sha=$UPG_SHA (from $UPG_SQUASHFS)"
else
  EXP_ARGS="$EXP_ARGS $IMG=$EXP_SIZE:$EXP_SHA"
fi
BASEIMG=$(imgcheck); echo "base images: $BASEIMG"
case "$BASEIMG" in *"default_state=ok"*) ;; *) echo "BLOCKED: base images are not complete"; exit 1 ;; esac

DELAYS=(${DELAYS:-})
if [ "$MODE" = upgrade ]; then
  echo "===== control: uninterrupted add system image ====="
  ti=$(date +%s.%N)
  gssh "$INSTALL" | tail -1
  TU=$(echo "$(date +%s.%N) - $ti" | bc); echo "install took ${TU}s end to end"
  CTRL=$(imgcheck); echo "after install: $CTRL"
  case "$(kv "$CTRL" state)" in *"$IMG:ok"*) ;; *) echo "BLOCKED: the uninterrupted install did not produce a complete $IMG"; exit 1 ;; esac
  echo "  rebooting cleanly into it"
  gssh "echo $PW | sudo -S -p '' poweroff" >/dev/null 2>&1
  P=$(qemu_pid) && wait_gone "$P"; rm -f "${RUN:?}"/*.sock "${RUN:?}/qemu.pid"
  boot "$ov"
  if wait_ssh 400; then
    push_checker   # /tmp does not survive a reboot
    R=$(imgcheck); echo "after reboot: $R"
    [ "$(kv "$R" running)" = "$IMG" ] && echo "  the new image boots (running=$IMG)" \
      || { echo "BLOCKED: rebooted but not into $IMG"; exit 1; }
  else
    echo "  console: $(console_screen)"; echo "BLOCKED: the completed new image does not boot"; exit 1
  fi
  stop_vm
  if [ -z "${TRIGGER:-}" ]; then
    DELAYS=(); for f in $FRACTIONS; do DELAYS+=("$(echo "scale=2; $f * $TU / 1" | bc)"); done
    echo "cut delays from FRACTIONS=[$FRACTIONS] x ${TU}s: ${DELAYS[*]}"
  else
    echo "cuts are triggered by grub.cfg's first change, at +${DELAYS[*]} seconds"
  fi
else
  stop_vm
fi

pass=0; fail=0; n=0
for d in "${DELAYS[@]}"; do
  n=$((n + 1))
  echo "===== trial $n: cut ${d}s after $([ "$MODE" = boot ] && echo 'qemu starts' || { [ -n "${TRIGGER:-}" ] && echo "grub.cfg first changes" || echo 'the install is sent'; }) ====="
  ov=$OUT/trial-$n.qcow2; rm -f "$ov"; qemu-img create -q -f qcow2 -b "$BASE" -F qcow2 "$ov"
  boot "$ov"
  if [ "$MODE" = upgrade ]; then
    wait_ssh 400 || { echo "  BLOCKED: trial $n never booted before the cut"; fail=$((fail + 1)); stop_vm; continue; }
    push_checker
    P=$(qemu_pid) || { echo "  BLOCKED: no qemu pid"; fail=$((fail + 1)); continue; }
    ( gssh "$INSTALL" >/dev/null 2>&1 & )
    if [ -n "${TRIGGER:-}" ]; then
      # The dangerous window is "grub.cfg already names the new image, its data is
      # not on disk yet". Its width does not depend on how long the install
      # takes, and how long it takes moves with host load (24s to 33s were seen),
      # so a fraction of the install time can miss it. Wait for the event instead.
      W=$(T=240 rootcmd 'P=/run/live/persistence/vda2/boot/grub/grub.cfg; o=$(stat -c %.9Y $P); while [ "$(stat -c %.9Y $P)" = "$o" ]; do sleep 0.05; done; echo changed' | tail -1)
      [ "$W" = changed ] || { echo "  BLOCKED: grub.cfg never changed (got: $W)"; fail=$((fail + 1)); stop_vm; continue; }
    fi
  else
    P=$(qemu_pid) || { echo "  BLOCKED: no qemu pid"; fail=$((fail + 1)); continue; }
  fi
  sleep "$d"
  kill -9 "$P" && echo "  cut: SIGKILL qemu $P at +${d}s"
  t0=$(date +%s.%N); wait_gone "$P"
  echo "  killed qemu gone after $(echo "$(date +%s.%N) - $t0" | bc)s"
  rm -f "${RUN:?}"/*.sock "${RUN:?}/qemu.pid"
  boot "$ov"; t1=$(date +%s)
  if ! wait_ssh "${POST_CUT_TIMEOUT:-900}"; then
    echo "  FAIL: no ssh ${POST_CUT_TIMEOUT:-900}s after the cut; qemu alive: $(qemu_pid >/dev/null && echo yes || echo NO)"
    echo "  console: $(console_screen)"
    fail=$((fail + 1)); stop_vm; continue
  fi
  echo "  back to ssh after $(( $(date +%s) - t1 ))s"
  push_checker
  S=$(inspect); echo "  $S"
  I=$(imgcheck); echo "  $I"
  ok=1; why=""
  [ "$(kv "$S" sha)" = "$OLDSHA" ] || { ok=0; why="$why config-changed"; }
  echo "$S" | grep -q "fs=rw" || { ok=0; why="$why fs-not-rw"; }
  echo "$S" | grep -q "failed=0" || { ok=0; why="$why failed-units"; }
  # Every image grub can load must exist in full, and the default must be one.
  bad=$(kv "$I" state | tr ',' '\n' | grep -v ':ok$' | tr '\n' ' ')
  [ -z "$bad" ] || { ok=0; why="$why referenced-image-incomplete($bad)"; }
  [ "$(kv "$I" default_state)" = ok ] || { ok=0; why="$why default-not-complete"; }
  if [ "$MODE" = upgrade ]; then
    run=$(kv "$I" running)
    if [ "$run" = "$IMG" ]; then
      echo "  outcome: the new image was complete and became the running system"
    else
      have=$(kv "$I" refs | tr ',' '\n' | grep -c "^$IMG$")
      echo "  outcome: still on $run; new image referenced by grub: $([ "$have" -gt 0 ] && echo yes || echo no); orphan dirs: $(kv "$I" orphans)"
      echo "  retrying the install on the survivor"
      RT=$(gssh "$INSTALL" | tail -1); echo "  retry: $RT"
      I2=$(imgcheck); echo "  after retry: $I2"
      case "$(kv "$I2" state)" in *"$IMG:ok"*) echo "  the retry completed the upgrade" ;; *) ok=0; why="$why retry-did-not-recover" ;; esac
    fi
  else
    [ "$(kv "$I" running)" = 2608 ] || { ok=0; why="$why unexpected-image"; }
  fi
  if [ $ok -eq 1 ]; then echo "  PASS"; pass=$((pass + 1)); else echo "  FAIL:$why"; fail=$((fail + 1)); fi
  stop_vm
done
echo
echo "===== $MODE: $pass passed, $fail failed of $n cuts ====="
[ $fail -eq 0 ]
