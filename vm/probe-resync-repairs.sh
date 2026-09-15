#!/bin/bash
# Does an FPM reconnect repair drift, or only reconnect?
#
# The previous probe showed a reconnect re-sends something -- output bytes 472
# to 1072, items processed 2 to 4 -- with four routes in play. Two items is not
# four routes, so "the reconnect walks the whole RIB" was not established, and
# Auto Recovery would have been designed on top of a number that does not add
# up.
#
# Counting bytes cannot settle it. What settles it is making drift that is real
# and then asking whether the reconnect closes it.
#
# The method: take the FPM session down, add routes to zebra while it is down
# so the data plane never hears about them, confirm the two sides disagree,
# then bring the session back and look again. If the drift closes, a reconnect
# is a repair primitive whatever its counters mean. If it does not, then
# nothing in this architecture repairs drift today and Reconciliation needs a
# different answer before it needs a loop.
#
# Scale is part of the design. Twenty routes rather than two, because an
# increment of "+2" is consistent with both a full resync and a counter that
# counts something other than routes; an increment that tracks twenty is not.
#
# TOPO=ipsec, R1 only. Every route added is removed again.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-/home/aikon/danos/.obs/probe-resync-repairs.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.155
N=20

exec > "$OUT" 2>&1
"$HERE/image-fingerprint.sh"
S() { docker exec danos-robot timeout 180 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$1" "$2" 2>&1; }

drift_json() { S $R1 "sudo python3 /tmp/dpa-drift.py --json 2>&1" | tail -1; }
field() { printf '%s' "$1" | grep -o "\"$2\": *[0-9]*" | grep -o '[0-9]*'; }
fpm_items() { S $R1 "sudo vtysh -c 'show fpm counters' 2>/dev/null | grep -i 'items processed' | grep -oE '[0-9]+'" | tail -1; }

echo "===== 0. Install the comparison ====="
b64=$(base64 -w0 "$HERE/dpa-drift.py")
S $R1 "echo '$b64' | base64 -d | sudo tee /tmp/dpa-drift.py >/dev/null
       sudo chmod 755 /tmp/dpa-drift.py; echo installed" | tail -1 | sed 's/^/    /'

echo
echo "===== 1. Baseline ====="
base=$(drift_json)
echo "    $base" | cut -c1-200
bd=$(field "$base" desired); bp=$(field "$base" programmed)
echo "    desired=$bd programmed_keys=$bp  items=$(fpm_items)"

echo
echo "===== 2. Take the FPM session down ====="
S $R1 "sudo vtysh -c 'configure terminal' -c 'no fpm address 127.0.0.1' 2>&1 | head -2" | sed 's/^/    /'
sleep 4
S $R1 "sudo ss -tn state established 2>/dev/null | grep -c 2620" | tail -1 | sed 's/^/    established sessions on 2620: /'

echo
echo "===== 3. Add $N routes while it is down ====="
cmds=""
for i in $(seq 1 $N); do cmds="$cmds -c 'ip route 10.90.$i.0/24 blackhole'"; done
S $R1 "sudo vtysh -c 'configure terminal' $cmds 2>&1 | head -3" | sed 's/^/    /'
sleep 5
mid=$(drift_json)
md=$(field "$mid" desired); mp=$(field "$mid" programmed)
echo "    desired=$md programmed_keys=$mp"
if [ "${md:-0}" -gt "${bd:-0}" ] && [ "${mp:-0}" -eq "${bp:-0}" ]; then
	echo "    DRIFT CREATED: zebra gained $((md - bd)), the data plane gained $((mp - bp))"
else
	echo "    NO CLEAN DRIFT -- the session may not really be down; the rest"
	echo "    of this probe cannot mean anything, so read no further."
fi

echo
echo "===== 4. Bring the session back ====="
before_items=$(fpm_items)
S $R1 "sudo vtysh -c 'configure terminal' -c 'fpm address 127.0.0.1' 2>&1 | head -2" | sed 's/^/    /'
sleep 10
after_items=$(fpm_items)
echo "    items processed: $before_items -> $after_items  (delta $((after_items - before_items)) for $N routes)"

echo
echo "===== 5. Did the drift close? ====="
end=$(drift_json)
ed=$(field "$end" desired); ep=$(field "$end" programmed)
echo "    desired=$ed programmed_keys=$ep"
if [ "${ep:-0}" -ge "${md:-0}" ]; then
	echo "    REPAIRED: the reconnect re-sent what the data plane had missed."
	echo "    A reconnect is a repair primitive, whatever its counters count."
elif [ "${ep:-0}" -gt "${mp:-0}" ]; then
	echo "    PARTIAL: the data plane gained $((ep - mp)) of $((md - bd)) missing."
	echo "    A reconnect re-sends some of the RIB, not all of it -- which is"
	echo "    the worst of the three answers, because a repair that half works"
	echo "    looks like one that worked."
else
	echo "    NOT REPAIRED: the data plane gained nothing. Nothing in this"
	echo "    architecture closes drift today, and Reconciliation needs a"
	echo "    different answer before it needs a loop."
fi

echo
echo "===== 6. Clean up ====="
cmds=""
for i in $(seq 1 $N); do cmds="$cmds -c 'no ip route 10.90.$i.0/24 blackhole'"; done
S $R1 "sudo vtysh -c 'configure terminal' $cmds 2>&1 | head -2" > /dev/null
sleep 5
fin=$(drift_json)
echo "    desired=$(field "$fin" desired) programmed_keys=$(field "$fin" programmed)  (baseline was $bd / $bp)"
S $R1 "sudo rm -f /tmp/dpa-drift.py" > /dev/null
