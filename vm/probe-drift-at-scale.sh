#!/bin/bash
# What does any of this cost with a real number of routes?
#
# Everything measured so far used four routes, or twenty. Both numbers are
# small enough that nothing has a cost worth noticing, and both are far from
# where drift actually happens -- a box with a full table, where a repair that
# stalls forwarding is worse than the drift it fixes.
#
# Three costs, none of them known:
#
#   the comparison   two JSON dumps and a set difference. Linear, presumably,
#                    but "presumably" is how the VRF numbering was handled
#                    before it was measured.
#   the resync       an FPM reconnect re-sends. Twenty routes arrived. How long
#                    does a large table take, and is there a window where the
#                    data plane holds less than it did?
#   forwarding       the one a counter cannot answer. If the resync empties and
#                    refills, traffic stops for that window, and nothing in the
#                    counters would say so.
#
# The third is why this exists. A repair primitive that is fast and correct on
# twenty routes and drops the table on twenty thousand is worse than no repair
# primitive, because it will be trusted.
#
# TOPO=ipsec, R1 only. Every route added is removed.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-/home/aikon/danos/.obs/probe-drift-at-scale.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.155
N=${N:-2000}

exec > "$OUT" 2>&1
"$HERE/image-fingerprint.sh"
S() { docker exec danos-robot timeout 600 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$1" "$2" 2>&1; }

dp_count() {
	S $R1 "sudo /opt/vyatta/bin/vplsh -l -c 'dpa object show route' 2>/dev/null | python3 -c 'import sys,json
print(len(json.load(sys.stdin)[\"dpa_objects\"][\"objects\"]))' 2>/dev/null" | tail -1
}

echo "===== 0. Install ====="
b64=$(base64 -w0 "$HERE/dpa-drift.py")
S $R1 "echo '$b64' | base64 -d | sudo tee /tmp/dpa-drift.py >/dev/null
       sudo chmod 755 /tmp/dpa-drift.py; echo installed" | tail -1 | sed 's/^/    /'
echo "    baseline dataplane routes: $(dp_count)"

echo
echo "===== 1. Load $N routes ====="
# Written to a file and sourced, because $N vtysh -c arguments overruns the
# command line long before the interesting numbers.
S $R1 "python3 -c '
with open(\"/tmp/bulk.conf\",\"w\") as f:
    f.write(\"configure terminal\n\")
    for i in range($N):
        f.write(\"ip route 10.%d.%d.0/24 blackhole\n\" % (128 + i // 256, i % 256))
    f.write(\"end\n\")
print(\"written\")'" | tail -1 | sed 's/^/    /'
t0=$(date +%s)
S $R1 "sudo vtysh -f /tmp/bulk.conf 2>&1 | tail -2" | sed 's/^/    /'
sleep 20
t1=$(date +%s)
echo "    load took $((t1 - t0))s wall"
echo "    dataplane routes now: $(dp_count)"

echo
echo "===== 2. What the comparison costs ====="
S $R1 "cd /tmp && time sudo python3 /tmp/dpa-drift.py --json > /tmp/drift.json 2>/dev/null; head -c 260 /tmp/drift.json" 2>&1 | sed 's/^/    /'

echo
echo "===== 3. Break the session, so the resync has work to do ====="
S $R1 "sudo vtysh -c 'configure terminal' -c 'no fpm address 127.0.0.1'" > /dev/null
sleep 4
S $R1 "python3 -c '
with open(\"/tmp/bulk2.conf\",\"w\") as f:
    f.write(\"configure terminal\n\")
    for i in range(200):
        f.write(\"ip route 10.200.%d.0/24 blackhole\n\" % i)
    f.write(\"end\n\")'" > /dev/null
S $R1 "sudo vtysh -f /tmp/bulk2.conf 2>&1 | tail -1" | sed 's/^/    /'
sleep 6
echo "    dataplane routes while disconnected: $(dp_count)  (should not have grown)"

echo
echo "===== 4. Reconnect, and watch the table while it happens ====="
# Sampled, not read once at the end. A dip that refills would be invisible to a
# before-and-after reading, and a dip is the failure mode that matters.
before=$(dp_count)
S $R1 "sudo vtysh -c 'configure terminal' -c 'fpm address 127.0.0.1'" > /dev/null
for i in 1 2 3 4 5 6 7 8; do
	sleep 3
	printf '    t+%2ds  routes %s\n' "$((i * 3))" "$(dp_count)"
done
after=$(dp_count)
echo "    before $before  after $after  (expected about $((before + 200)))"
if [ "${after:-0}" -lt "${before:-0}" ]; then
	echo "    THE TABLE SHRANK -- the resync empties before it refills, and"
	echo "    forwarding stops for that window."
fi

echo
echo "===== 5. Did forwarding survive? ====="
S $R1 "ping -c 3 -W 2 10.0.2.2 2>&1 | tail -2" | sed 's/^/    /'

echo
echo "===== 6. Clean up ====="
S $R1 "python3 -c '
with open(\"/tmp/bulkdel.conf\",\"w\") as f:
    f.write(\"configure terminal\n\")
    for i in range($N):
        f.write(\"no ip route 10.%d.%d.0/24 blackhole\n\" % (128 + i // 256, i % 256))
    for i in range(200):
        f.write(\"no ip route 10.200.%d.0/24 blackhole\n\" % i)
    f.write(\"end\n\")'" > /dev/null
S $R1 "sudo vtysh -f /tmp/bulkdel.conf 2>&1 | tail -1" | sed 's/^/    /'
sleep 20
echo "    dataplane routes after cleanup: $(dp_count)"
S $R1 "sudo rm -f /tmp/dpa-drift.py /tmp/bulk*.conf /tmp/drift.json" > /dev/null
