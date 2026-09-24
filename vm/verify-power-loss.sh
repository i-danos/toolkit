#!/bin/bash
# P2: does an installed system survive a hard power cut during a config commit?
#
# The cut is SIGKILL to the qemu process, by pidfile after checking the
# process really is qemu. From the guest's side that is what a power failure
# is: whatever the guest had not yet handed to the virtual disk is gone, and
# what it had flushed is kept. It is NOT a host power loss -- the host's own
# page cache survives, so this says nothing about a guest whose flushes the
# hypervisor ignores. Stated so a pass is not read as more than it is.
#
# Each trial boots its own qcow2 overlay of one quiesced base disk, so trials
# are independent and the base is never written. The operation that is cut is
# "commit; save" of 40 static routes, which rewrites /config/config.boot. The
# delay is counted from the moment the commit is sent, and a control trial
# with no cut supplies the "new" version of the file, the baseline supplies
# the "old" one. A survivor must boot AND hold exactly one of the two.
#
# Usage: verify-power-loss.sh <iso> <base.qcow2> <outdir> [delay ...]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ISO=${1:?usage: verify-power-loss.sh <iso> <base.qcow2> <outdir> [delay ...]}
BASE=${2:?base disk}
OUT=${3:?outdir}
shift 3
DELAYS=("$@"); [ ${#DELAYS[@]} -eq 0 ] && DELAYS=(0.6 1.2 1.8 2.4 3.0 3.8)
NAME=plr
SSHPORT=${SSHPORT:-2298}
RUN=${OBS_DIR:-/home/aikon/danos/.obs}/run/$NAME
PW=vyatta
mkdir -p "$OUT" "$RUN"
LOG=$OUT/power-loss.log
exec > >(tee "$LOG") 2>&1

gssh() {
  docker exec danos-robot timeout ${T:-90} sshpass -p "$PW" ssh -p "$SSHPORT" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
    vyatta@192.168.203.1 "$1" 2>&1
}
wait_ssh() {
  local deadline=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(T=20 gssh 'echo up' | tail -1)" = up ] && return 0
    sleep 8
  done
  return 1
}
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
    print(repr(buf.decode(errors="replace")[-400:]) if buf else "(silent)")
except Exception as e:
    print("(console unreachable: %s)" % e)
PY
}
qemu_pid() {
  local p; p=$(cat "$RUN/qemu.pid" 2>/dev/null)
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  tr '\0' ' ' </proc/$p/cmdline 2>/dev/null | grep -q qemu-system || return 1
  echo "$p"
}
# Returns only once the process is really gone. On a host under memory
# pressure a qemu can take minutes to exit after SIGKILL (0.2s, 32s, 130s and
# 432s were all measured here), and starting the next VM before then fails
# silently: the old process still holds the image's write lock and the port.
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
sudo_g() { gssh "echo $PW | sudo -S -p '' $1"; }

# One line of facts about the state after a boot.
inspect() {
  T=120 gssh "echo $PW | sudo -S -p '' sh -c '
    sha=\$(sha256sum /config/config.boot | cut -c1-16); sz=\$(stat -c%s /config/config.boot)
    routes=\$(grep -c \"10\\.[0-9]*\\.0\\.0/24\" /config/config.boot)
    live=\$(vtysh -c \"show ip route static\" 2>/dev/null | grep -c \"10\\.[0-9]*\\.0\\.0/24\")
    fserr=\$(dmesg | grep -ciE \"EXT4-fs.*(error|recover|orphan)|I/O error\")
    act=\$(systemctl is-active configd vyatta-dataplane frr | tr \"\\n\" \",\")
    failed=\$(systemctl --failed --no-legend | wc -l)
    rw=\$(touch /config/.wtest 2>/dev/null && echo rw && rm -f /config/.wtest || echo RO)
    echo sha=\$sha size=\$sz cfgroutes=\$routes liveroutes=\$live fserr=\$fserr active=\$act failed=\$failed fs=\$rw
  '" | tail -1
}

STAGE='SID=4242; eval "$(cli-shell-api getSessionEnv $SID)"; cli-shell-api setupSession >/dev/null 2>&1; for i in $(seq 1 40); do vcli -s $SID -c "set protocols static route 10.$i.0.0/24 blackhole" >/dev/null 2>&1; done; echo staged'
FIRE='SID=4242; eval "$(cli-shell-api getSessionEnv $SID)"; vcli -s $SID -c commit >/dev/null 2>&1; vcli -s $SID -c save >/dev/null 2>&1; echo finished'

echo "===== base ====="
stop_vm
ov=$OUT/control.qcow2; rm -f "$ov"
qemu-img create -q -f qcow2 -b "$BASE" -F qcow2 "$ov"
boot "$ov"
wait_ssh 300 || { echo "BLOCKED: base does not boot to ssh"; exit 1; }
OLD=$(inspect); echo "old  $OLD"
OLDSHA=$(echo "$OLD" | sed 's/.*sha=\([0-9a-f]*\).*/\1/')
echo "===== control: commit and save, no cut ====="
gssh "$STAGE" | tail -1
tc0=$(date +%s.%N)
gssh "$FIRE" | tail -1
TC=$(echo "$(date +%s.%N) - $tc0" | bc)
echo "commit+save took ${TC}s end to end, ssh round trip included"
NEW=$(inspect); echo "new  $NEW"
NEWSHA=$(echo "$NEW" | sed 's/.*sha=\([0-9a-f]*\).*/\1/')
stop_vm
[ "$OLDSHA" != "$NEWSHA" ] || { echo "BLOCKED: the commit did not change config.boot, so old and new cannot be told apart"; exit 1; }

# FRACTIONS="0.5 0.8" places the cuts at those fractions of the control's own
# commit+save time instead of at fixed seconds. A fixed delay is fragile: how
# long the commit takes moves with host load, and so does the delay at which the
# file flips from old to new -- two runs at the same 2.4s gave both answers.
if [ -n "${FRACTIONS:-}" ]; then
  DELAYS=(); for f in $FRACTIONS; do DELAYS+=("$(echo "scale=2; $f * $TC / 1" | bc)"); done
  echo "cut delays from FRACTIONS=[$FRACTIONS] x ${TC}s: ${DELAYS[*]}"
fi
pass=0; fail=0; n=0
for d in "${DELAYS[@]}"; do
  n=$((n + 1))
  echo "===== trial $n: cut ${d}s after the commit is sent ====="
  ov=$OUT/trial-$n.qcow2; rm -f "$ov"
  qemu-img create -q -f qcow2 -b "$BASE" -F qcow2 "$ov"
  boot "$ov"
  wait_ssh 300 || { echo "  BLOCKED: trial $n never booted before the cut"; fail=$((fail + 1)); stop_vm; continue; }
  gssh "$STAGE" | tail -1 >/dev/null
  P=$(qemu_pid) || { echo "  BLOCKED: no qemu pid"; fail=$((fail + 1)); continue; }
  ( gssh "$FIRE" >/dev/null 2>&1 & )
  sleep "$d"
  kill -9 "$P" && echo "  cut: SIGKILL qemu $P at +${d}s"
  t0=$(date +%s.%N)
  while kill -0 "$P" 2>/dev/null; do sleep 0.2; done
  echo "  killed qemu gone after $(echo "$(date +%s.%N) - $t0" | bc)s"
  rm -f "${RUN:?}"/*.sock "${RUN:?}/qemu.pid"
  boot "$ov"
  t1=$(date +%s)
  if ! wait_ssh "${POST_CUT_TIMEOUT:-900}"; then
    echo "  FAIL: no ssh ${POST_CUT_TIMEOUT:-900}s after the cut; qemu alive: $(qemu_pid >/dev/null && echo yes || echo NO)"
    echo "  console: $(console_screen)"
    echo "  qemu.log: $(tail -c 300 "$RUN/qemu.log" 2>/dev/null | tr '\n' ' ')"
    fail=$((fail + 1)); stop_vm; continue
  fi
  echo "  back to ssh after $(( $(date +%s) - t1 ))s"
  echo "  boot: $(T=60 gssh 'systemd-analyze 2>&1 | head -1' | tail -1)"
  S=$(inspect); echo "  $S"
  sha=$(echo "$S" | sed 's/.*sha=\([0-9a-f]*\).*/\1/')
  verdict=OTHER
  [ "$sha" = "$OLDSHA" ] && verdict=OLD
  [ "$sha" = "$NEWSHA" ] && verdict=NEW
  cfg=$(echo "$S" | sed 's/.*cfgroutes=\([0-9]*\).*/\1/'); live=$(echo "$S" | sed 's/.*liveroutes=\([0-9]*\).*/\1/')
  ok=1
  [ "$verdict" = OTHER ] && ok=0
  [ "$cfg" != "$live" ] && ok=0
  echo "$S" | grep -q "fs=rw" || ok=0
  echo "$S" | grep -q "failed=0" || ok=0
  echo "  config=$verdict  file-routes=$cfg live-routes=$live"
  if [ $ok -eq 1 ]; then echo "  PASS"; pass=$((pass + 1)); else echo "  FAIL"; fail=$((fail + 1)); fi
  stop_vm
done
echo
echo "===== $pass passed, $fail failed of $n cuts ====="
[ $fail -eq 0 ]
