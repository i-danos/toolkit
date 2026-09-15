#!/bin/bash
# What makes brokerd crash: the routes, or the session?
#
# Two crashes were seen first during bulk route operations, and the defect was
# written up as "brokerd segfaults under bulk route load". Both probes that saw
# it happened to bounce the FPM session at the end of their bulk phase, so the
# two were never separated.
#
# This separates them. Each phase counts coredumps before and after, and the
# count is the only signal that matters -- brokerd restarts either way, so
# "is it running" answers nothing and process age answers it only indirectly.
#
#   A  bulk load and delete, session left alone
#   B  bounce the session, table left small
#   C  load while the session is down, then reconnect
#
# The answer was B, every time, and A never. The route count is irrelevant.
#
# Pre-fix this produces one core per bounce in phase B. Post-fix it produces
# none, and that is the regression test: run it against any brokerd change that
# touches thread lifetime or the dp_data sockets.
#
# TOPO=ipsec, R1 only. Every route added is removed.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-/home/aikon/danos/.obs/probe-brokerd-crash.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=${R1:-192.168.203.155}
N=${N:-2000}
BOUNCES=${BOUNCES:-10}

exec > "$OUT" 2>&1
"$HERE/image-fingerprint.sh"
S() { docker exec danos-robot timeout 600 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$R1" "$1" 2>&1; }

cores() { S "sudo ls /var/lib/systemd/coredump/ 2>/dev/null | grep -c brokerd" | tail -1; }
age()   { S "ps -o etimes= -C brokerd 2>/dev/null | head -1 | tr -d ' '" | tail -1; }

# Age is reported alongside the core count because the two disagree in the
# informative direction: a young brokerd with no new core is a clean restart,
# which is what the fix produces and what the design does on every bounce.
status() { printf '    %-22s age %ss  cores %s\n' "$1" "$(age)" "$(cores)"; }

bulk() { # bulk <add|no> <count> <first-octet>
	local verb=$1 n=$2 base=$3 pfx=""
	[ "$verb" = no ] && pfx="no "
	S "python3 -c '
with open(\"/tmp/bulk.conf\",\"w\") as f:
    f.write(\"configure terminal\n\")
    for i in range($n):
        f.write(\"${pfx}ip route 10.%d.%d.0/24 blackhole\n\" % ($base + i // 256, i % 256))
    f.write(\"end\n\")'" > /dev/null
	S "sudo vtysh -f /tmp/bulk.conf >/dev/null 2>&1; echo done" | tail -1 > /dev/null
}

bounce() {
	S "sudo vtysh -c 'configure terminal' -c 'no fpm address 127.0.0.1' >/dev/null 2>&1
	   sudo vtysh -c 'configure terminal' -c 'fpm address 127.0.0.1' >/dev/null 2>&1; echo bounced" | tail -1 > /dev/null
}

start_cores=$(cores)
status start

echo
echo "===== A. bulk load only, no FPM bounce ====="
bulk add "$N" 128;  sleep 15; status "after add"
bulk no  "$N" 128;  sleep 15; status "after delete"
a_cores=$(cores)

echo
echo "===== B. FPM bounce only, small table ====="
for i in $(seq 1 "$BOUNCES"); do
	bounce
	sleep 6
	status "bounce $i"
done
b_cores=$(cores)

echo
echo "===== C. bulk load with the session down, then reconnect ====="
S "sudo vtysh -c 'configure terminal' -c 'no fpm address 127.0.0.1'" > /dev/null
sleep 4
bulk add 200 200; sleep 8; status "loaded while down"
S "sudo vtysh -c 'configure terminal' -c 'fpm address 127.0.0.1'" > /dev/null
sleep 12; status "after reconnect"
bulk no 200 200; sleep 12; status cleaned
c_cores=$(cores)

echo
echo "===== Verdict ====="
printf '    phase A (load only)    %s new core(s)\n' "$((a_cores - start_cores))"
printf '    phase B (bounce only)  %s new core(s) over %s bounces\n' "$((b_cores - a_cores))" "$BOUNCES"
printf '    phase C (both)         %s new core(s)\n' "$((c_cores - b_cores))"
echo
if [ "$((c_cores - start_cores))" -eq 0 ]; then
	echo "    BROKERD SURVIVED -- no coredump in any phase."
	rc=0
else
	echo "    BROKERD CRASHED. The phase with the new cores is the trigger;"
	echo "    if that is B, the route count has nothing to do with it."
	rc=1
fi
S "sudo rm -f /tmp/bulk.conf" > /dev/null
exit $rc
