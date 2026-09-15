#!/bin/bash
# Does the watch loop tell a transient apart from real drift, and does it keep
# its hands off?
#
# A single comparison cannot separate the two. The path is asynchronous --
# zebra pushes, brokerd queues, the data plane programs -- so a route added a
# moment ago is legitimately "desired not programmed" until it lands. Every
# probe written against this pipeline sleeps for several seconds before reading
# for exactly that reason, and a loop that did not would report drift for
# ordinary traffic.
#
# What the loop reports is therefore not whether a disagreement exists but how
# many consecutive cycles it has survived. That number is what a trigger
# condition would be written against, and it does not exist yet -- which is why
# nothing here repairs. The available repair is a whole-session FPM reconnect;
# a loop acting on an unknown threshold with that primitive would reset the
# routing plane on a schedule.
#
# The checks:
#
#   1  a settled box shows no persistent disagreement. Without this, every
#      later count could be noise and would still look like a finding.
#   2  real drift is counted, and the count *rises* across cycles. A detector
#      that reports drift once is indistinguishable from one that reports a
#      route in flight.
#   3  the drift is still there afterwards. This is the one that matters: the
#      loop must not have repaired anything, and "drift gone" would be
#      indistinguishable from a successful detection followed by a silent fix.
#   4  the count resets when the drift clears, so a stale count cannot
#      accumulate into a false trigger later.
#
# TOPO=ipsec, R1 only. Routes added are removed again.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-/home/aikon/danos/.obs/verify-drift-watch.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.155
pass=0
fail=0

exec > "$OUT" 2>&1
"$HERE/image-fingerprint.sh"
S() { docker exec danos-robot timeout 240 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$1" "$2" 2>&1; }
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; shift; printf '%s\n' "$@" | head -5 | sed 's/^/        /'; fail=$((fail + 1)); }

echo "===== 0. Install ====="
b64=$(base64 -w0 "$HERE/dpa-drift.py")
S $R1 "echo '$b64' | base64 -d | sudo tee /tmp/dpa-drift.py >/dev/null
       sudo chmod 755 /tmp/dpa-drift.py; echo installed" | tail -1 | sed 's/^/    /'

echo
echo "===== 1. A settled box has nothing persistent ====="
out=$(S $R1 "sudo python3 /tmp/dpa-drift.py --watch 2 --cycles 3 2>&1")
printf '%s\n' "$out" | sed 's/^/    /'
n=$(printf '%s' "$out" | grep -oE 'disagreements [0-9]+' | tail -1 | grep -oE '[0-9]+')
if [ "${n:-1}" -eq 0 ]; then
	ok "three cycles on a settled box, no disagreement"
else
	bad "three cycles on a settled box, no disagreement" \
	    "$n reported -- every count below would be noise and still look like a finding"
fi

echo
echo "===== 2. Real drift, and the count rises ====="
# Drift that cannot heal itself: the session is down, so these never arrive.
S $R1 "sudo vtysh -c 'configure terminal' -c 'no fpm address 127.0.0.1'" > /dev/null
sleep 3
S $R1 "sudo vtysh -c 'configure terminal' -c 'ip route 10.91.1.0/24 blackhole' -c 'ip route 10.91.2.0/24 blackhole'" > /dev/null
sleep 3
out=$(S $R1 "sudo python3 /tmp/dpa-drift.py --watch 2 --cycles 4 2>&1")
printf '%s\n' "$out" | sed 's/^/    /'
first=$(printf '%s' "$out" | grep -oE '10\.91\.1\.0/24  [0-9]+ cycle' | head -1 | grep -oE '[0-9]+ cycle' | grep -oE '[0-9]+')
last=$(printf '%s' "$out" | grep -oE '10\.91\.1\.0/24  [0-9]+ cycle' | tail -1 | grep -oE '[0-9]+ cycle' | grep -oE '[0-9]+')
if [ -n "$last" ] && [ "${last:-0}" -gt "${first:-0}" ]; then
	ok "the count rises across cycles ($first -> $last), so it is persistence not a one-shot"
else
	bad "the count rises across cycles" "first=$first last=$last"
fi

echo
echo "===== 3. It did not repair ====="
# The one that matters. A loop that quietly fixed things would show the same
# clean comparison as a loop that detected correctly and stopped.
still=$(S $R1 "sudo python3 /tmp/dpa-drift.py --json 2>&1" | tail -1)
miss=$(printf '%s' "$still" | grep -o '"desired_not_programmed": \[[^]]*\]' | grep -c '10.91')
if [ "${miss:-0}" -ge 1 ]; then
	ok "the drift is still there after watching -- the loop repaired nothing"
else
	bad "the drift is still there after watching" \
	    "it is gone, which means something fixed it; a detector must not" \
	    "$still"
fi

echo
echo "===== 4. The count resets when the drift clears ====="
S $R1 "sudo vtysh -c 'configure terminal' -c 'fpm address 127.0.0.1'" > /dev/null
sleep 10
out=$(S $R1 "sudo python3 /tmp/dpa-drift.py --watch 2 --cycles 3 2>&1")
printf '%s\n' "$out" | tail -4 | sed 's/^/    /'
n=$(printf '%s' "$out" | grep -oE 'disagreements [0-9]+' | tail -1 | grep -oE '[0-9]+')
if [ "${n:-1}" -eq 0 ]; then
	ok "once the reconnect delivered them, the count went back to zero"
else
	bad "the count went back to zero" "still $n -- a stale count would trigger falsely later"
fi

echo
echo "===== 5. Clean up ====="
S $R1 "sudo vtysh -c 'configure terminal' -c 'no ip route 10.91.1.0/24 blackhole' -c 'no ip route 10.91.2.0/24 blackhole'" > /dev/null
sleep 5
S $R1 "sudo python3 /tmp/dpa-drift.py 2>&1 | head -2; sudo rm -f /tmp/dpa-drift.py" | sed 's/^/    /'

echo
echo "===== Result ====="
printf '  %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
	echo "  DRIFT IS WATCHED, NOT ACTED ON. Persistence is counted so that a"
	echo "  threshold can be chosen from evidence later, and the repair the"
	echo "  loop prints is one an operator runs."
fi
exit "$fail"
