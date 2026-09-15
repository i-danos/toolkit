#!/bin/bash
# Does an FPM bounce blank the forwarding table?
#
# This question has been answered three times with three different reasons, and
# the first two were wrong in ways worth keeping on the page:
#
#   1. "An FPM resync empties the table."  Drawn from a probe that caught
#      "routes 0" across a reconnect. It would have been written down as an
#      architectural constraint.
#   2. "No -- that was brokerd crashing."  Correct, and not the whole answer.
#      The empty table was a restarted data plane, and the crash was a real
#      defect (pthread_cancel on a thread holding a mutex, fixed in
#      vyatta-route-broker 1.0.5).
#   3. The table empties anyway.  brokerd accept()s one FPM connection and
#      closes its listening socket -- one session per process, by design -- so
#      a bounce ends the process, systemd restarts it, and the data plane
#      restarts with its feed.
#
# So the conclusion the crash was standing in front of survives the crash being
# fixed, for a different reason, and this exists to keep it measured rather
# than remembered. It asserts both halves:
#
#   - no coredump, because a crash would make the dip mean the old thing again
#   - the dip happens, because that is the finding
#
# A run where brokerd crashes is not a pass with extra noise; it is a different
# experiment, and the assertions below separate the two.
#
# TOPO=ipsec, R1 only. Every route added is removed.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-/home/aikon/danos/.obs/probe-bounce-blanks-table.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=${R1:-192.168.203.155}
N=${N:-500}
# Bounces, and samples taken inside the guest per bounce. Both matter -- see
# the note above section 2 on why one bounce and a slow sampler is not enough.
BOUNCES=${BOUNCES:-3}
ITERS=${ITERS:-300}

exec > "$OUT" 2>&1
"$HERE/image-fingerprint.sh"
S() { docker exec danos-robot timeout 300 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$R1" "$1" 2>&1; }

dp_count() {
	S "sudo /opt/vyatta/bin/vplsh -l -c 'dpa object show route' 2>/dev/null | python3 -c 'import sys,json
print(len(json.load(sys.stdin)[\"dpa_objects\"][\"objects\"]))' 2>/dev/null" | tail -1
}
cores() { S "sudo ls /var/lib/systemd/coredump/ 2>/dev/null | grep -c brokerd" | tail -1; }

bulk() { # bulk <add|no> <count>
	local pfx=""; [ "$1" = no ] && pfx="no "
	S "python3 -c '
with open(\"/tmp/bt.conf\",\"w\") as f:
    f.write(\"configure terminal\n\")
    for i in range($2):
        f.write(\"${pfx}ip route 10.%d.%d.0/24 blackhole\n\" % (170 + i // 256, i % 256))
    f.write(\"end\n\")'" > /dev/null
	S "sudo vtysh -f /tmp/bt.conf >/dev/null 2>&1; echo done" > /dev/null
}

echo "===== 1. Load $N routes ====="
S "sudo rm -f /var/lib/systemd/coredump/*brokerd* 2>/dev/null" > /dev/null
start_cores=$(cores)
bulk add "$N"
sleep 12
before=$(dp_count)
echo "    dataplane routes: $before   cores: $start_cores"

echo
echo "===== 2. Bounce the FPM session, sampling the table across it ====="
# Sampled inside the guest, in a tight loop, across several bounces. Every part
# of that sentence was paid for:
#
#   in the guest   one ssh round trip per sample was the resolution limit, not
#                  the box. At roughly 3s per sample the dip was missed
#                  entirely and the probe reported that it never happened.
#   tight          even in-guest, parsing JSON per iteration costs more than
#                  the window. The count still has to be read, so the loop is
#                  kept to that and nothing else.
#   several        at ~23 iterations a second the dip was still missed in 1 of
#                  3 bounces. It is short. One bounce showing nothing is a
#                  sampling result, not a finding.
#
# So the restart is asserted on the pid, which is observable every time, and
# the dip is reported as "seen in k of N" rather than pass/fail on one look.
# A probe that had to catch a short window on the first try would fail a third
# of the time on a box behaving exactly as described.
seen=0; pidchanged=0; lowest=$before
for b in $(seq 1 "$BOUNCES"); do
	res=$(S "p0=\$(pgrep -x dataplane | head -1)
	   sudo vtysh -c 'configure terminal' -c 'no fpm address 127.0.0.1' >/dev/null 2>&1
	   sudo vtysh -c 'configure terminal' -c 'fpm address 127.0.0.1' >/dev/null 2>&1
	   low=$before; unreadable=0
	   for i in \$(seq 1 $ITERS); do
	     n=\$(sudo /opt/vyatta/bin/vplsh -l -c 'dpa object show route' 2>/dev/null | python3 -c 'import sys,json
try: print(len(json.load(sys.stdin)[\"dpa_objects\"][\"objects\"]))
except Exception: print(-1)' 2>/dev/null)
	     [ \"\$n\" = \"-1\" ] && unreadable=\$((unreadable+1)) && continue
	     [ -n \"\$n\" ] && [ \"\$n\" -lt \"\$low\" ] && low=\$n
	   done
	   p1=\$(pgrep -x dataplane | head -1)
	   echo \"RESULT low=\$low unreadable=\$unreadable p0=\$p0 p1=\$p1\"" | grep '^RESULT' | tail -1)
	low=$(printf '%s' "$res" | sed -n 's/.*low=\([0-9-]*\).*/\1/p')
	unread=$(printf '%s' "$res" | sed -n 's/.*unreadable=\([0-9]*\).*/\1/p')
	p0=$(printf '%s' "$res" | sed -n 's/.*p0=\([0-9]*\).*/\1/p')
	p1=$(printf '%s' "$res" | sed -n 's/.*p1=\([0-9]*\).*/\1/p')
	printf '    bounce %s  lowest %s  unreadable %s  dataplane pid %s -> %s' \
	       "$b" "${low:-?}" "${unread:-?}" "${p0:-?}" "${p1:-?}"
	[ -n "$p0" ] && [ -n "$p1" ] && [ "$p0" != "$p1" ] && { pidchanged=$((pidchanged + 1)); printf '  (restarted)'; }
	case "$low" in ''|*[!0-9]*) ;; *)
		[ "$low" -lt "$lowest" ] && lowest=$low
		[ "$low" -lt "$before" ] && { seen=$((seen + 1)); printf '  (blanked)'; } ;;
	esac
	printf '\n'
done
after=$(dp_count)
end_cores=$(cores)

echo
echo "===== 3. Clean up ====="
bulk no "$N"
sleep 10
echo "    dataplane routes: $(dp_count)"
S "sudo rm -f /tmp/bt.conf" > /dev/null

echo
echo "===== Result ====="
printf '    before %s   lowest seen %s   after %s   new cores %s\n' \
       "$before" "$lowest" "$after" "$((end_cores - start_cores))"
printf '    the data plane restarted in %s of %s bounces; the table was caught\n' "$pidchanged" "$BOUNCES"
printf '    blanked in %s of %s\n' "$seen" "$BOUNCES"
rc=0
if [ "$((end_cores - start_cores))" -eq 0 ]; then
	echo "    PASS  brokerd produced no coredump -- the dip below is not a crash"
else
	echo "    FAIL  brokerd crashed ($((end_cores - start_cores)) core(s)); this run measures the"
	echo "          old defect, not the design property. Fix the crash first."
	rc=1
fi
# The restart is the half that is observable every time, so it is the one the
# run is allowed to fail on.
if [ "$pidchanged" -eq "$BOUNCES" ]; then
	echo "    PASS  the data plane was replaced on every bounce"
else
	printf '    FAIL  the data plane survived %s of %s bounces -- if it no longer\n' \
	       "$((BOUNCES - pidchanged))" "$BOUNCES"
	echo "          restarts with its feed, this whole finding needs redoing"
	rc=1
fi
if [ "$seen" -gt 0 ]; then
	printf '    PASS  the table was blanked in %s of %s bounces (%s -> %s -> %s)\n' \
	       "$seen" "$BOUNCES" "$before" "$lowest" "$after"
else
	echo "    FAIL  the blanking was not caught in any bounce. The window is short"
	echo "          and a miss is expected sometimes, so try a larger BOUNCES first;"
	echo "          if it stays unseen while the data plane still restarts, the"
	echo "          table is being repopulated before it is ever observable and"
	echo "          the conclusion below needs restating."
	rc=1
fi
if [ "$rc" -eq 0 ]; then
	echo
	echo "    An FPM bounce blanks the forwarding table on a box where brokerd"
	echo "    does not crash. It cannot be an automatic repair primitive,"
	echo "    whatever its end state looks like."
fi
exit $rc
