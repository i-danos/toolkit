#!/bin/bash
# mroute class: pause vplaned on R2, add a new SSM join on R3 (host-side driver).
#
# Induces a real, persistent control-plane/data-plane disagreement by pausing
# one delivery process (SIGSTOP) on the transit router R2 and resuming it
# (SIGCONT) afterwards, so zebra holds state the data plane never receives. No
# test hook, no FPM bounce (a bounce triggers zebra's full RIB walk, which
# repairs the drift before it can be observed). Run on TOPO=fw; the drift tools
# must already be in /tmp on R2. Measured: unicast route and MPLS label
# delivery go through brokerd, multicast (S,G) through vplaned.
# Host-side driver: pause brokerd on R2, add a new SSM join on R3, watch R2.
SSH="docker exec danos-robot sshpass -p vyatta ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
R2=vyatta@192.168.203.156; R3=vyatta@192.168.203.157
cli() { $SSH $1 "SID=\$\$; eval \"\$(cli-shell-api getSessionEnv \$SID)\"; cli-shell-api setupSession; vcli -s \$SID -c '$2' >/dev/null 2>&1; vcli -s \$SID -c commit 2>&1 | tail -1" 2>&1 | grep -v Welcome; }
$SSH $R2 'sudo /opt/vyatta/bin/vplsh -l -c "debug nl_route" >/dev/null 2>&1; rm -f /tmp/w.jsonl; nohup sudo python3 /tmp/dpa-drift.py --watch 2 --cycles 22 --json > /tmp/w.jsonl 2>&1 < /dev/null & sleep 1; echo started' 2>&1 | grep -v Welcome
sleep 3
$SSH $R2 'BP=$(pgrep -x vplaned|head -1); [ "$(cat /proc/$BP/comm)" = vplaned ] && sudo kill -STOP $BP && echo "STOPPED $BP $(date -u +%T)"' 2>&1 | grep -v Welcome
cli $R3 'set interfaces dataplane dp0s9 ip igmp join-group 232.1.1.3 source 65.1.1.2'; echo "join committed $(date -u +%T)"
sleep 22
$SSH $R2 'BP=$(pgrep -x vplaned|head -1); sudo kill -CONT $BP && echo "RESUMED $(date -u +%T)"; sudo vtysh -c "show ip mroute" | head -8' 2>&1 | grep -v Welcome
sleep 25
cli $R3 'delete interfaces dataplane dp0s9 ip igmp join-group 232.1.1.3'
$SSH $R2 'sudo /opt/vyatta/bin/vplsh -l -c "debug -nl_route" >/dev/null 2>&1; echo cleaned' 2>&1 | grep -v Welcome
