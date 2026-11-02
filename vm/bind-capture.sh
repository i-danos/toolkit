#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-only
# Raw captures for the BIND-r1 judges on R1 of a TOPO=ipsec topology that is already up (boot-and-prep.sh TOPO=ipsec <iso>).
# It only captures: no judge is run here, so no scenario can be shaped by a verdict. Everything lands in <outdir>/<item>/.
#
# Usage: bind-capture.sh <outdir> [item ...]     items: vlan route6 commits netlink   (default: all)
#   vlan     -> dpa_object_model_interface_vlan and ..._routed_ports (same captures)
#   route6   -> comparison_scope_route6
#   commits  -> drift_event_correlation_config_commits
#   netlink  -> drift_event_correlation_netlink
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?usage: bind-capture.sh <outdir> [item ...]}; shift
ITEMS=${*:-vlan route6 commits netlink}
R1=${R1:-192.168.203.155}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
PARENT=${PARENT:-dp0s8}; VID=${VID:-100}
mkdir -p "$OUT"
S() { docker exec danos-robot timeout "${T:-240}" sshpass -p vyatta ssh $SSH_OPTS "vyatta@$R1" "$1" 2>&1 | grep -v '^Warning: Permanently\|^Welcome to'; }
log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/capture.log"; }
VPLSH='sudo /opt/vyatta/bin/vplsh -l -c'
# commit CLI lines on R1 in a fresh session; prints the commit output
cfg() {
  local lines="" l
  for l in "$@"; do lines="$lines; vcli -s \$SID -c \"$l\""; done
  S "SID=\$\$; eval \"\$(cli-shell-api getSessionEnv \$SID)\"; cli-shell-api setupSession >/dev/null 2>&1 $lines; vcli -s \$SID -c commit 2>&1 | tail -4; cli-shell-api teardownSession >/dev/null 2>&1; echo cfg-done"
}
install_tools() {
  local f b
  for f in dpa-drift.py dpa-coverage-manifest.py dpa-drift-history.py dpa-drift-correlate.py dpa-drift-correlate-netlink.py; do
    b=$(base64 -w0 "$HERE/$f"); S "echo '$b' | base64 -d | sudo tee /tmp/$f >/dev/null; sudo chmod 755 /tmp/$f" >/dev/null
  done
  log "tools installed on R1: $(S 'ls /tmp/dpa-*.py | tr "\n" " "')"
}
provenance() {
  { echo "== date"; S 'date -u +%FT%TZ'; echo "== uname"; S 'uname -r'; echo "== show version"; S '/opt/vyatta/bin/vyatta-op-cmd-wrapper show version 2>&1 | head -12'
    echo "== dataplane/frr/configd"; S 'systemctl is-active vyatta-dataplane frr configd'; echo "== ip -br link"; S 'ip -br link'; } > "$OUT/provenance-r1.txt"
}
wait_dataplane() {  # up to 240 s until `dpa object show interface` answers with objects
  local i; for i in $(seq 1 48); do
    S "$VPLSH 'dpa object show interface' 2>&1 | head -c 300" | grep -q '"objects"' && return 0; sleep 5; done; return 1
}
watch_bg() {  # watch_bg <cycles> : start the drift watch on R1 in the background
  S "sudo rm -f /tmp/watch.jsonl /tmp/watch.err; sudo sh -c 'nohup python3 /tmp/dpa-drift.py --watch 2 --cycles $1 --json > /tmp/watch.jsonl 2>/tmp/watch.err < /dev/null &'; echo started" >/dev/null
}
fpm_off() { S "sudo vtysh -c 'configure terminal' -c 'no fpm address 127.0.0.1'" >/dev/null; }
fpm_on()  { S "sudo vtysh -c 'configure terminal' -c 'fpm address 127.0.0.1'" >/dev/null; }
wait_watch_done() { local i; for i in $(seq 1 60); do [ "$(S 'pgrep -f "[d]pa-drift.py --watch" >/dev/null && echo run || echo done')" = done ] && return 0; sleep 3; done; return 1; }
commit_log() { S "sudo journalctl -u configd --no-pager -o short-iso --since '-20 min' | grep 'COMMIT: Commit OVERALL'"; }

install_tools; provenance
for item in $ITEMS; do
  D=$OUT/$item; mkdir -p "$D"
  case $item in
  vlan)
    log "vlan: parent $PARENT vid $VID"
    S "$VPLSH 'dpa object show interface'" > "$D/before.json"
    S '/opt/vyatta/bin/vyatta-op-cmd-wrapper show interfaces' > "$D/show-interfaces-before.txt"
    cfg "set interfaces dataplane $PARENT vif $VID" > "$D/commit.txt"; log "commit: $(tr '\n' ' ' < "$D/commit.txt")"
    sleep 8
    S "$VPLSH 'dpa object show interface'" > "$D/after-config.json"
    S '/opt/vyatta/bin/vyatta-op-cmd-wrapper show interfaces' > "$D/show-interfaces.txt"
    S 'echo vyatta | sudo -S -p "" systemctl restart vyatta-dataplane; echo restarted' > "$D/restart.txt"; log "dataplane restarted"
    sleep 15; wait_dataplane && log "dataplane answers again" || log "dataplane did NOT answer within 240 s"
    sleep 15
    S "$VPLSH 'dpa object show interface'" > "$D/after-restart.json"
    S '/opt/vyatta/bin/vyatta-op-cmd-wrapper show interfaces' > "$D/show-interfaces-after-restart.txt"
    ;;
  route6)
    cfg "set protocols static route6 2001:db8:91::/64 blackhole" "set protocols static route6 2001:db8:92::/64 blackhole" > "$D/commit.txt"; log "commit: $(tr '\n' ' ' < "$D/commit.txt")"
    sleep 20
    S 'sudo python3 /tmp/dpa-drift.py --json 2>&1' | tail -1 > "$D/drift.json"
    S "sudo vtysh -c 'show ipv6 route json'" > "$D/zebra-ipv6.json"
    S "sudo vtysh -c 'show ipv6 route'" > "$D/zebra-ipv6.txt"
    ;;
  commits)
    cfg "delete protocols static route6 2001:db8:91::/64" "delete protocols static route6 2001:db8:92::/64" >/dev/null; sleep 10
    S 'sudo python3 /tmp/dpa-drift.py --watch 2 --cycles 2 2>&1 | tail -2' > "$D/settled-before.txt"
    watch_bg 24; log "watch started"
    sleep 4;  fpm_off; log "fpm off"
    sleep 4;  cfg "set protocols static route 10.93.1.0/24 blackhole" > "$D/commit-1.txt"; log "commit 1: $(tr '\n' ' ' < "$D/commit-1.txt")"
    sleep 8;  cfg "set protocols static route 10.93.2.0/24 blackhole" > "$D/commit-2.txt"; log "commit 2: $(tr '\n' ' ' < "$D/commit-2.txt")"
    sleep 12; fpm_on; log "fpm on"
    wait_watch_done || log "watch did not finish"
    S 'cat /tmp/watch.jsonl' > "$D/watch.jsonl"; S 'cat /tmp/watch.err' > "$D/watch.err"
    S 'sudo python3 /tmp/dpa-drift-history.py /tmp/watch.jsonl' > "$D/events.json"
    S 'sudo python3 /tmp/dpa-drift-history.py /tmp/watch.jsonl > /tmp/events.json; sudo python3 /tmp/dpa-drift-correlate.py /tmp/events.json' > "$D/correlated.json"
    commit_log > "$D/configd-commits.txt"
    cfg "delete protocols static route 10.93.1.0/24" "delete protocols static route 10.93.2.0/24" >/dev/null
    ;;
  netlink)
    S "$VPLSH 'debug nl_route'" > "$D/debug-on.txt"; log "debug nl_route: $(tr '\n' ' ' < "$D/debug-on.txt" | cut -c1-100)"
    watch_bg 24; log "watch started"
    sleep 4;  cfg "set protocols static route 10.94.1.0/24 blackhole" > "$D/commit-add.txt"; log "route added (delivery working)"
    sleep 6;  fpm_off; log "fpm off"
    sleep 3;  cfg "delete protocols static route 10.94.1.0/24" > "$D/commit-delete.txt"; log "route deleted while fpm is down"
    sleep 14; fpm_on; log "fpm on"
    wait_watch_done || log "watch did not finish"
    S 'cat /tmp/watch.jsonl' > "$D/watch.jsonl"
    S 'sudo python3 /tmp/dpa-drift-history.py /tmp/watch.jsonl > /tmp/events.json; sudo python3 /tmp/dpa-drift-correlate-netlink.py /tmp/events.json' > "$D/correlated-netlink.json"
    S "sudo journalctl -u vyatta-dataplane --no-pager -o short-iso --since '-10 min' | grep -E 'RTM_(NEW|DEL)ROUTE' | grep '10.94.1' | head -12" > "$D/dataplane-netlink-lines.txt"
    S "$VPLSH 'debug no nl_route'" > "$D/debug-off.txt"
    ;;
  esac
  log "$item captured -> $D"
done
S 'sudo rm -f /tmp/dpa-*.py /tmp/watch.* /tmp/events.json' >/dev/null
log "done"
