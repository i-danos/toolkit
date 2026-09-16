#!/bin/bash
# P2: can a single-route replay repair a route that is genuinely missing?
#
# P1 (probe-replay-one-scope.sh) established what the primitive does to a route
# that is already present: one update, live session, nothing restarted. It could
# not establish repair, because nothing in this system could make a route go
# missing without also fixing it -- the only lever was an FPM session bounce,
# and a bounce runs zebra's full RIB walk.
#
# So the loss is injected on the wire instead, by fpm-filter.py sitting between
# zebra and brokerd:
#
#     zebra --(2621)--> fpm-filter --(2620)--> brokerd --> dataplane
#
# That matters for what this probe can claim. brokerd is not modified and still
# listens on 2620; zebra is redirected by configuration, not by code. The route
# is lost the way a delivery failure loses one -- sent by zebra, never received
# by brokerd -- rather than by a component being taught to pretend.
#
# fpm-filter.py is fault injection. It is a test instrument and has no place on
# a production forwarding path.
#
# The assertion that does the most work here is the data plane's pid. The
# recovery path this project already had -- brokerd crashing, systemd
# restarting it, broker_dump_routes() re-seeding from the kernel FIB -- also
# ends with the route present, and was once written up as a repair on exactly
# that evidence. It changes the pid. A repair does not.
#
# Requires: the patched dplane_fpm_nl.so, brokerd running with -d, a vty
# password on zebra, and fpm-filter.py at /tmp/fpm-filter.py.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-/home/aikon/danos/.obs/probe-replay-one-repair.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=${R1:-192.168.203.155}
VTYPASS=${VTYPASS:-zebra}
TARGET=${TARGET:-10.91.9.0/24}
PROXY_PORT=${PROXY_PORT:-2621}

exec > "$OUT" 2>&1
"$HERE/image-fingerprint.sh"
S() { docker exec danos-robot timeout 300 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$R1" "$1" 2>&1; }

broker_msgs() {
	S "sudo journalctl -u brokerd --no-pager 2>/dev/null \
	   | grep -oE 'processed [0-9]+' | tail -1 | awk '{print \$2}'" | tail -1
}
dp_pid()    { S "pgrep -x dataplane | head -1" | tail -1; }
dp_count()  {
	S "sudo /opt/vyatta/bin/vplsh -l -c 'dpa object show route' 2>/dev/null | python3 -c 'import sys,json
print(len(json.load(sys.stdin)[\"dpa_objects\"][\"objects\"]))' 2>/dev/null" | tail -1
}
dp_has()    { S "sudo /opt/vyatta/bin/vplsh -l -c 'dpa object show route' 2>/dev/null | grep -c '${TARGET%/*}'" | tail -1; }
rib_has()   { S "sudo vtysh -c 'show ip route $TARGET json' 2>/dev/null | grep -c prefix" | tail -1; }
fpm_closes() {
	S "sudo vtysh -d zebra -c 'show fpm counters' 2>/dev/null \
	   | grep -F 'Connection closes' | awk -F: '{print \$2}' | tr -d ' '" | tail -1
}
zebra_vty() {
	S "(printf '%s\n' '$VTYPASS'; sleep 1; printf 'enable\n'; sleep 1;
	    printf '%s\n' '$VTYPASS'; sleep 1; printf '%s\n' '$1'; sleep 3; printf 'exit\n') \
	   | timeout 25 telnet 127.0.0.1 2601 2>&1 | tr -d '\r'"
}

cleanup() {
	S "sudo vtysh -c 'configure terminal' -c 'no ip route $TARGET blackhole'" > /dev/null 2>&1
	S "sudo systemctl stop fpm-filter" > /dev/null 2>&1
	S "sudo vtysh -c 'configure terminal' -c 'no fpm address 127.0.0.1' >/dev/null 2>&1
	   sudo vtysh -c 'configure terminal' -c 'fpm address 127.0.0.1' >/dev/null 2>&1" > /dev/null 2>&1
}
trap cleanup EXIT

echo "===== 1. Arm the filter to lose $TARGET, once ====="
S "sudo systemctl stop fpm-filter 2>/dev/null; sleep 1
   sudo systemd-run --unit=fpm-filter --collect python3 /tmp/fpm-filter.py \
     --listen $PROXY_PORT --connect 127.0.0.1:2620 --drop $TARGET --state /tmp/filter.json" > /dev/null 2>&1
sleep 2
printf '    filter: %s\n' "$(S "systemctl is-active fpm-filter" | tail -1)"

S "sudo vtysh -c 'configure terminal' -c 'no fpm address 127.0.0.1' >/dev/null 2>&1
   sudo vtysh -c 'configure terminal' -c 'fpm address 127.0.0.1 port $PROXY_PORT' >/dev/null 2>&1" > /dev/null 2>&1
sleep 10
printf '    zebra connected through the filter: %s\n' \
       "$(S "sudo vtysh -d zebra -c 'show fpm status' 2>/dev/null | grep -F Connected | awk '{print \$2}'" | tail -1)"

echo
echo "===== 2. Add the route; the filter eats it in flight ====="
S "sudo vtysh -c 'configure terminal' -c 'ip route $TARGET blackhole'" > /dev/null 2>&1
sleep 8
S "sudo journalctl -u fpm-filter --no-pager 2>/dev/null | grep -F 'dropped' | tail -2" | sed 's/^/    /'

d_rib=$(rib_has); d_dp=$(dp_has)
printf '    in the RIB: %s   in the data plane: %s\n' "$d_rib" "$d_dp"
if [ "${d_rib:-0}" -eq 0 ] || [ "${d_dp:-0}" -ne 0 ]; then
	echo
	echo "    ABORT: the drift was not created. Either zebra never learned the"
	echo "    route, or the filter did not lose it -- either way there is"
	echo "    nothing here to repair and a pass would mean nothing."
	exit 2
fi

echo
echo "===== 3. Before the repair ====="
b_pid=$(dp_pid); b_msgs=$(broker_msgs); b_closes=$(fpm_closes); b_routes=$(dp_count)
printf '    dataplane pid %s   broker msgs %s   fpm closes %s   routes %s\n' \
       "$b_pid" "$b_msgs" "$b_closes" "$b_routes"

echo
echo "===== 4. Repair ====="
out=$(zebra_vty "fpm route-replay $TARGET")
printf '%s\n' "$out" | grep -E '^%' | sed 's/^/    /'
said_ok=$(printf '%s' "$out" | grep -c "Re-sent")
sleep 6

echo
echo "===== 5. After ====="
a_pid=$(dp_pid); a_msgs=$(broker_msgs); a_closes=$(fpm_closes); a_routes=$(dp_count)
a_dp=$(dp_has)
printf '    dataplane pid %s   broker msgs %s (+%s)   fpm closes %s   routes %s\n' \
       "$a_pid" "$a_msgs" "$((a_msgs - b_msgs))" "$a_closes" "$a_routes"
printf '    %s in the data plane: %s\n' "$TARGET" "$a_dp"

echo
echo "===== Result ====="
rc=0
chk() {
	if [ "$1" = 1 ]; then printf '    PASS  %s\n' "$2"
	else printf '    FAIL  %s\n' "$3"; rc=1; fi
}

chk "$([ "$said_ok" -ge 1 ] && echo 1 || echo 0)" \
    "the command reported the route re-sent" "the command did not report success"

chk "$([ "${a_dp:-0}" -ge 1 ] && echo 1 || echo 0)" \
    "the missing route is in the data plane again" \
    "the route is still missing -- no repair happened"

delta=$((a_msgs - b_msgs))
chk "$([ "$delta" -eq 1 ] && echo 1 || echo 0)" \
    "exactly one route update crossed the FPM boundary" \
    "$delta updates crossed the boundary, expected 1"

chk "$([ "$delta" -lt "$b_routes" ] && echo 1 || echo 0)" \
    "no full RIB replay: $delta update(s) against $b_routes programmed routes" \
    "the count moved like a full replay ($delta vs $b_routes)"

chk "$([ "$a_closes" = "$b_closes" ] && echo 1 || echo 0)" \
    "the FPM session is the same one (closes $b_closes -> $a_closes)" \
    "the FPM session was torn down (closes $b_closes -> $a_closes)"

# The one that separates a repair from the recovery path this project already
# had. brokerd crashing and re-seeding from the kernel FIB also ends with the
# route present; it does not end with the same pid.
chk "$([ "$a_pid" = "$b_pid" ] && echo 1 || echo 0)" \
    "the data plane was not restarted (pid $b_pid)" \
    "the data plane restarted ($b_pid -> $a_pid) -- this is a reseed, not a repair"

chk "$([ "$a_routes" = "$((b_routes + 1))" ] && echo 1 || echo 0)" \
    "the table grew by exactly the repaired route ($b_routes -> $a_routes)" \
    "the table went $b_routes -> $a_routes, expected $((b_routes + 1))"

echo
if [ "$rc" -eq 0 ]; then
	echo "    ROUTE-LEVEL REPAIR WORKS. A route lost in delivery was put back by"
	echo "    naming it, over the live session, with one message, and without"
	echo "    restarting the data plane. Route-level repair and session-level"
	echo "    recovery are separate primitives, and this is the first evidence"
	echo "    in this project that distinguishes them."
else
	echo "    The repair did not hold up. Read the failures above before"
	echo "    treating route-level repair as available."
fi
exit $rc
