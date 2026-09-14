#!/bin/bash
# If drift is found, what is there to do about it?
#
# Drift detection works. Auto Recovery needs somewhere to write, and the data
# plane has no route-injection entry point at all -- "route" in its command
# table is display-only. Routes arrive as a stream: zebra -> FPM -> brokerd ->
# ZMQ -> data plane, and a stream has no seek.
#
# So the repair primitive for this architecture is probably not "write the
# missing route" but "ask for the stream again". Two things in the source point
# that way and neither has been seen to work:
#
#   fpm_reconnect() in dplane_fpm_nl.c cancels t_ribreset and t_ribwalk, plus
#   the nexthop-group, LSP and RMAC equivalents. A reset-and-walk pair is
#   full-resync machinery, so a reconnect should re-send the entire RIB.
#
#   brokerd calls broker_dump_routes() exactly once, from broker_main.c:219 --
#   at startup. It seeds from the kernel and never re-seeds, so it is not a
#   place to ask for anything.
#
# What this establishes:
#
#   1  whether FRR 10.3 exposes the counters at all -- the reading below is
#      worthless without a before and after
#   2  whether a reconnect actually re-sends, rather than merely reconnecting
#   3  what it costs: a whole-RIB resync to repair one route is coarse, and how
#      coarse is a number worth having before designing around it
#   4  whether forwarding survives it. A repair that briefly empties the
#      forwarding table is worse than the drift it fixes, and that would not be
#      visible in a counter.
#
# TOPO=ipsec, R1 only.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-/home/aikon/danos/.obs/probe-repair-path.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.155

exec > "$OUT" 2>&1
"$HERE/image-fingerprint.sh"
S() { docker exec danos-robot timeout 120 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$1" "$2" 2>&1; }

echo "===== 1. Does FRR 10.3 expose FPM counters? ====="
S $R1 "sudo vtysh -c 'show fpm counters' 2>&1 | head -20" | sed 's/^/    /'

echo
echo "===== 2. Is the session up, and who is on the other end? ====="
S $R1 "sudo ss -tnp state established 2>/dev/null | grep 2620" | sed 's/^/    /'

echo
echo "===== 3. What the data plane holds before ====="
S $R1 "sudo /opt/vyatta/bin/vplsh -l -c 'dpa object show route' 2>/dev/null | python3 -c 'import sys,json
o=json.load(sys.stdin)[\"dpa_objects\"][\"objects\"]
print(len(o), \"routes\")' 2>/dev/null" | tail -1 | sed 's/^/    /'

echo
echo "===== 4. Force a reconnect and see whether the RIB is re-sent ====="
# Removing and restoring the FPM address is the documented way to make the
# session come up again; FNE_RECONNECT is what the module raises for it.
S $R1 "sudo vtysh -c 'configure terminal' -c 'no fpm address 127.0.0.1' 2>&1 | head -2" | sed 's/^/    /'
sleep 3
S $R1 "sudo vtysh -c 'configure terminal' -c 'fpm address 127.0.0.1' 2>&1 | head -2" | sed 's/^/    /'
sleep 6
echo "    counters after:"
S $R1 "sudo vtysh -c 'show fpm counters' 2>&1 | head -20" | sed 's/^/      /'

echo
echo "===== 5. Did forwarding survive it? ====="
S $R1 "sudo /opt/vyatta/bin/vplsh -l -c 'dpa object show route' 2>/dev/null | python3 -c 'import sys,json
o=json.load(sys.stdin)[\"dpa_objects\"][\"objects\"]
print(len(o), \"routes\")' 2>/dev/null" | tail -1 | sed 's/^/    /'
echo "    and the comparison still agrees:"
b64=$(base64 -w0 "$HERE/dpa-drift.py")
S $R1 "echo '$b64' | base64 -d | sudo tee /tmp/dpa-drift.py >/dev/null
       sudo chmod 755 /tmp/dpa-drift.py
       sudo python3 /tmp/dpa-drift.py 2>&1 | head -4
       sudo rm -f /tmp/dpa-drift.py" | sed 's/^/      /'

echo
echo "===== 6. Is there anything finer-grained? ====="
# If a single route can be re-asked for, the repair need not be a whole-RIB
# resync. This is the question that decides whether Auto Recovery is surgical
# or a sledgehammer.
S $R1 "sudo vtysh -c 'list' 2>/dev/null | grep -iE 'fpm|dplane' | head -10" | sed 's/^/    /'
