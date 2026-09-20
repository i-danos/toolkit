#!/bin/bash
# Read-only DPA object coverage probe for P1 drift diagnostics.
# Usage: probe-dpa-coverage.sh [management-ip]
set -u

R=${1:-192.168.203.155}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
OUT=${OUT:-/home/aikon/danos/.obs/dpa-coverage-$(date +%Y%m%dT%H%M%S).json}

S() { docker exec danos-robot timeout 30 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$R" "$1" 2>/dev/null; }

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }
probe() {
    local name=$1 cmd=$2 out rc state
    out=$(S "$cmd"); rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
        state=unreadable
    elif printf '%s' "$out" | grep -q 'dpa_objects'; then
        state=enumerable
    elif printf '%s' "$out" | grep -qiE 'unknown command|not found|not supported|not enumerable'; then
        state=not_enumerable
    else
        state=unreadable
    fi
    printf '%s\t%s\n' "$name" "$state"
}

mkdir -p "$(dirname "$OUT")"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
probe route "sudo /opt/vyatta/bin/vplsh -l -c 'dpa object show route'" >>"$tmp"
probe route6 "sudo /opt/vyatta/bin/vplsh -l -c 'dpa object show route6'" >>"$tmp"
probe mpls-route "sudo /opt/vyatta/bin/vplsh -l -c 'dpa object show mpls-route'" >>"$tmp"
probe mroute "sudo /opt/vyatta/bin/vplsh -l -c 'dpa object show mroute'" >>"$tmp"
probe mroute6 "sudo /opt/vyatta/bin/vplsh -l -c 'dpa object show mroute6'" >>"$tmp"
probe qos-if "sudo /opt/vyatta/bin/vplsh -l -c 'dpa object show qos-if'" >>"$tmp"
probe qos-vlan "sudo /opt/vyatta/bin/vplsh -l -c 'dpa object show qos-vlan'" >>"$tmp"

python3 - "$R" "$OUT" "$tmp" <<'PY'
import json,sys,datetime
host,out,path=sys.argv[1:]
coverage={}
for line in open(path):
    name,state=line.rstrip().split('\t',1); coverage[name]=state
doc={'schema_version':1,'host':host,'generated_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'coverage':coverage,'read_only':True}
open(out,'w').write(json.dumps(doc,indent=2)+'\n')
print(json.dumps(doc))
PY
