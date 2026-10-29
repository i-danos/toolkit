#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-only
# mpls-route class: pause brokerd (default) or vplaned on R2, add a loopback on R1 (host-side driver). Needs LDP on top of OSPF.
#
# Induces a real, persistent control-plane/data-plane disagreement by pausing
# one delivery process (SIGSTOP) on the transit router R2 and resuming it
# (SIGCONT) afterwards, so zebra holds state the data plane never receives. No
# test hook, no FPM bounce (a bounce triggers zebra's full RIB walk, which
# repairs the drift before it can be observed). Run on TOPO=fw; the drift tools
# must already be in /tmp on R2. Measured: unicast route and MPLS label
# delivery go through brokerd, multicast (S,G) through vplaned.
PROC=${1:-brokerd}
SSH="docker exec danos-robot sshpass -p vyatta ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
R1=vyatta@192.168.203.155; R2=vyatta@192.168.203.156
# The pause below is a SIGSTOP on a real router. If this script is interrupted
# (Ctrl-C, ssh drop, timeout) the process stays stopped and every later test on
# that topology reads a frozen brokerd as product behaviour. Resume it on any exit
# path. The pid comes back on an explicit INDUCE_STOPPED_PID= marker line (never
# scraped out of other output), and the trap re-checks /proc/<pid>/comm before it
# signals anything, so a stale or wrong pid can never CONT another process.
STOPPED_PID=""; STOP_ATTEMPTED=""
resume_stopped() {
  [ -n "$STOP_ATTEMPTED" ] || return 0
  STOP_ATTEMPTED=""
  $SSH "$R2" "P='$STOPPED_PID'; [ -n \"\$P\" ] || P=\$(pgrep -x $PROC | head -1);
    if [ -z \"\$P\" ]; then echo '[trap] no $PROC process found, nothing to resume';
    elif [ \"\$(cat /proc/\$P/comm 2>/dev/null)\" = $PROC ]; then sudo kill -CONT \$P && echo \"[trap] resumed $PROC \$P\";
    else echo \"[trap] not resuming \$P: comm mismatch\"; fi" 2>&1 | grep -v Welcome
  STOPPED_PID=""
}
trap resume_stopped EXIT
trap 'resume_stopped; exit 130' INT
trap 'resume_stopped; exit 143' TERM
cliN() { local h=$1; shift; local cmds=""; for c in "$@"; do cmds="$cmds vcli -s \$SID -c \"$c\" 2>&1 | grep -v '^\s*\$';"; done
  $SSH $h "SID=\$\$; eval \"\$(cli-shell-api getSessionEnv \$SID)\"; cli-shell-api setupSession; $cmds vcli -s \$SID -c commit 2>&1 | tail -1" 2>&1 | grep -v Welcome; }
$SSH $R2 'sudo /opt/vyatta/bin/vplsh -l -c "debug nl_route" >/dev/null 2>&1; rm -f /tmp/w.jsonl; nohup sudo python3 /tmp/dpa-drift.py --watch 2 --cycles 24 --json > /tmp/w.jsonl 2>&1 < /dev/null & sleep 1' 2>&1 | grep -v Welcome
sleep 3
STOP_ATTEMPTED=1
stop_out=$($SSH $R2 "BP=\$(pgrep -x $PROC | head -1); if [ -n \"\$BP\" ] && [ \"\$(cat /proc/\$BP/comm 2>/dev/null)\" = $PROC ] && sudo kill -STOP \$BP; then echo \"STOPPED $PROC \$BP \$(date -u +%T)\"; echo \"INDUCE_STOPPED_PID=\$BP\"; else echo INDUCE_STOPPED_PID=; fi" 2>&1 | grep -v Welcome)
printf '%s\n' "$stop_out"
STOPPED_PID=$(printf '%s\n' "$stop_out" | sed -n 's/^INDUCE_STOPPED_PID=\([0-9][0-9]*\)$/\1/p' | tail -1)
cliN $R1 "set interfaces loopback lo1 address 9.9.9.9/32" "set protocols ospf area 0 network 9.9.9.9/32"; echo "R1 committed $(date -u +%T)"
sleep 25
$SSH $R2 "BP=\$(pgrep -x $PROC|head -1); sudo kill -CONT \$BP && echo \"RESUMED \$(date -u +%T)\"; sudo vtysh -c 'show mpls table'" 2>&1 | grep -v Welcome
STOPPED_PID=""; STOP_ATTEMPTED=""
sleep 25
cliN $R1 "delete protocols ospf area 0 network 9.9.9.9/32" "delete interfaces loopback lo1 address 9.9.9.9/32"
$SSH $R2 'sudo /opt/vyatta/bin/vplsh -l -c "debug -nl_route" >/dev/null 2>&1; echo cleaned' 2>&1 | grep -v Welcome
