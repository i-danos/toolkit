#!/bin/bash
# Route class: pause brokerd, commit a static route, watch, resume. Runs ON R2.
#
# Induces a real, persistent control-plane/data-plane disagreement by pausing
# one delivery process (SIGSTOP) on the transit router R2 and resuming it
# (SIGCONT) afterwards, so zebra holds state the data plane never receives. No
# test hook, no FPM bounce (a bounce triggers zebra's full RIB walk, which
# repairs the drift before it can be observed). Run on TOPO=fw; the drift tools
# must already be in /tmp on R2. Measured: unicast route and MPLS label
# delivery go through brokerd, multicast (S,G) through vplaned.
set -u
PFX=${PFX:-198.51.100.0/24}
BPID=$(pgrep -x brokerd | head -1)
[ -n "$BPID" ] && [ "$(cat /proc/$BPID/comm)" = brokerd ] || { echo "no brokerd"; exit 1; }
resume() { sudo kill -CONT "$BPID" 2>/dev/null; }
trap resume EXIT

sudo /opt/vyatta/bin/vplsh -l -c 'debug nl_route' >/dev/null 2>&1
rm -f /tmp/w.jsonl
sudo python3 /tmp/dpa-drift.py --watch 2 --cycles 20 --json > /tmp/w.jsonl 2>&1 &
WPID=$!
sleep 3

cli() { SID=$$; eval "$(cli-shell-api getSessionEnv $SID)"; cli-shell-api setupSession
        vcli -s $SID -c "$1" >/dev/null 2>&1; vcli -s $SID -c commit 2>&1 | tail -1; }

sudo kill -STOP "$BPID"; echo "brokerd STOPPED $(date -u +%T)"
cli "set protocols static route $PFX blackhole"; echo "committed $(date -u +%T)"
sleep 20
sudo kill -CONT "$BPID"; echo "brokerd RESUMED $(date -u +%T)"
wait $WPID
cli "delete protocols static route $PFX"
sudo /opt/vyatta/bin/vplsh -l -c 'debug -nl_route' >/dev/null 2>&1
echo "done $(date -u +%T)"
