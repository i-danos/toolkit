#!/bin/bash
# P1: what is the scope of "fpm route-replay <prefix>"?
#
# This does NOT test repair. It tests what the primitive does, on a route that
# is already present everywhere, which is a question that can be answered
# without first manufacturing drift -- and manufacturing drift is exactly what
# this system has no honest way to do yet. The only lever available for that is
# an FPM session bounce, and a bounce triggers the full RIB walk, which would
# do the repair before the primitive got a chance. So repair is P2, behind an
# FPM proxy that can drop one message; this is P1.
#
# Six properties, three about semantics and three about what the action must
# NOT have been:
#
#   target       the named route is re-sent
#   scope        exactly one route update crosses the FPM boundary
#   no full walk the other routes are not re-sent with it
#   session      the FPM connection is the same one
#   process      the data plane was not restarted
#   collateral   the forwarding table is unchanged
#
# The last three exist because this project recorded a restart as a repair
# once: an FPM reconnect was written up as "20 of 20 routes restored" when what
# happened was brokerd crashing, systemd restarting it, and broker_dump_routes()
# re-seeding the whole table from the kernel FIB. A primitive that cannot be
# told apart from a restart has not been demonstrated.
#
# The message count comes from brokerd's own processed_msg counter, on the
# receiving side of the FPM socket. That matters: it is not a number this
# patch produces, computes or can influence. bytes_sent from "show fpm
# counters" is recorded too, but only as corroboration -- bytes are an encoding
# length, not a message count, and they move with address family, next-hop
# count and attributes.
#
# Requires: the patched dplane_fpm_nl.so installed, brokerd running with -d,
# and a vty password set on zebra (vtysh rejects the command from its own
# compiled table before it ever reaches zebra).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-/home/aikon/danos/.obs/probe-replay-one-scope.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=${R1:-192.168.203.155}
VTYPASS=${VTYPASS:-zebra}
TARGET=${TARGET:-10.0.2.0/24}

exec > "$OUT" 2>&1
"$HERE/image-fingerprint.sh"
S() { docker exec danos-robot timeout 300 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$R1" "$1" 2>&1; }

# brokerd's count of route objects it has published, read from its debug log.
# One route update is one increment.
broker_msgs() {
	S "sudo journalctl -u brokerd --no-pager 2>/dev/null \
	   | grep -oE 'processed [0-9]+' | tail -1 | awk '{print \$2}'" | tail -1
}

dp_pid()    { S "pgrep -x dataplane | head -1" | tail -1; }
dp_routes() {
	S "sudo /opt/vyatta/bin/vplsh -l -c 'dpa object show route' 2>/dev/null | python3 -c 'import sys,json
print(len(json.load(sys.stdin)[\"dpa_objects\"][\"objects\"]))' 2>/dev/null" | tail -1
}
fpm_field() {  # fpm_field <label>
	S "sudo vtysh -d zebra -c 'show fpm counters' 2>/dev/null \
	   | grep -F '$1' | awk -F: '{print \$2}' | tr -d ' '" | tail -1
}
zebra_vty() {  # zebra_vty <command>
	S "(printf '%s\n' '$VTYPASS'; sleep 1; printf 'enable\n'; sleep 1;
	    printf '%s\n' '$VTYPASS'; sleep 1; printf '%s\n' '$1'; sleep 3; printf 'exit\n') \
	   | timeout 25 telnet 127.0.0.1 2601 2>&1 | tr -d '\r'"
}

echo "===== 0. The route under test must already be everywhere ====="
in_rib=$(S "sudo vtysh -c 'show ip route $TARGET json' 2>/dev/null | grep -c '\"prefix\"'" | tail -1)
in_dp=$(S "sudo /opt/vyatta/bin/vplsh -l -c 'dpa object show route' 2>/dev/null | grep -c '${TARGET%/*}'" | tail -1)
printf '    %s in the RIB: %s   in the data plane: %s\n' "$TARGET" "$in_rib" "$in_dp"
if [ "${in_rib:-0}" -eq 0 ] || [ "${in_dp:-0}" -eq 0 ]; then
	echo "    ABORT: the premise does not hold -- this probe replays a route that"
	echo "    is already present on both sides. A missing route is P2."
	exit 2
fi

echo
echo "===== 1. Before ====="
b_msgs=$(broker_msgs); b_pid=$(dp_pid); b_routes=$(dp_routes)
b_closes=$(fpm_field "Connection closes"); b_bytes=$(fpm_field "Output bytes")
printf '    broker messages   %s\n    dataplane pid     %s\n    dataplane routes  %s\n' \
       "$b_msgs" "$b_pid" "$b_routes"
printf '    fpm closes        %s\n    fpm output bytes  %s\n' "$b_closes" "$b_bytes"

echo
echo "===== 2. Replay one route ====="
out=$(zebra_vty "fpm route-replay $TARGET")
printf '%s\n' "$out" | grep -E '^%|Re-sent' | sed 's/^/    /'
said_ok=$(printf '%s' "$out" | grep -c "Re-sent")
sleep 6

echo
echo "===== 3. After ====="
a_msgs=$(broker_msgs); a_pid=$(dp_pid); a_routes=$(dp_routes)
a_closes=$(fpm_field "Connection closes"); a_bytes=$(fpm_field "Output bytes")
printf '    broker messages   %s  (+%s)\n' "$a_msgs" "$((a_msgs - b_msgs))"
printf '    dataplane pid     %s\n    dataplane routes  %s\n' "$a_pid" "$a_routes"
printf '    fpm closes        %s\n    fpm output bytes  %s  (+%s)\n' \
       "$a_closes" "$a_bytes" "$((a_bytes - b_bytes))"

echo
echo "===== Result ====="
rc=0
chk() {  # chk <ok?> <pass text> <fail text>
	if [ "$1" = 1 ]; then printf '    PASS  %s\n' "$2"
	else printf '    FAIL  %s\n' "$3"; rc=1; fi
}

chk "$([ "$said_ok" -ge 1 ] && echo 1 || echo 0)" \
    "the command reported the route re-sent" \
    "the command did not report success"

delta=$((a_msgs - b_msgs))
chk "$([ "$delta" -eq 1 ] && echo 1 || echo 0)" \
    "exactly one route update crossed the FPM boundary" \
    "$delta route updates crossed the boundary, expected 1"

# A full RIB walk would move the count by about the size of the table, so the
# scope check above already rules it out -- but state it as its own line,
# because "not a full replay" is the property, and a reader should not have to
# derive it from an arithmetic coincidence.
chk "$([ "$delta" -lt "$b_routes" ] && echo 1 || echo 0)" \
    "no full RIB replay: $delta update(s) against $b_routes programmed routes" \
    "the count moved like a full replay ($delta vs $b_routes routes)"

chk "$([ "$a_closes" = "$b_closes" ] && echo 1 || echo 0)" \
    "the FPM session is the same one (closes $b_closes -> $a_closes)" \
    "the FPM session was torn down (closes $b_closes -> $a_closes)"

chk "$([ "$a_pid" = "$b_pid" ] && echo 1 || echo 0)" \
    "the data plane was not restarted (pid $b_pid)" \
    "the data plane restarted ($b_pid -> $a_pid) -- this is not a repair"

chk "$([ "$a_routes" = "$b_routes" ] && echo 1 || echo 0)" \
    "the forwarding table is unchanged ($b_routes routes)" \
    "the forwarding table changed ($b_routes -> $a_routes)"

echo
if [ "$rc" -eq 0 ]; then
	echo "    REPLAY-ONE IS ONE. The primitive re-sends the route it was given,"
	echo "    one update, over the live session, without restarting anything."
	echo "    Whether it can repair a route that is missing is a separate"
	echo "    question and needs a way to make one go missing -- see P2."
else
	echo "    The primitive does not have the scope it claims. Nothing about"
	echo "    repair should be attempted until this reads clean."
fi
exit $rc
