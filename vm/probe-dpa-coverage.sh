#!/bin/bash
# Read-only DPA object coverage probe for P1 drift diagnostics.
# Usage: probe-dpa-coverage.sh [management-ip]
set -u

R=${1:-192.168.203.155}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
OUT=${OUT:-/home/aikon/danos/.obs/dpa-coverage-$(date +%Y%m%dT%H%M%S).json}

S() { docker exec danos-robot timeout 30 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$R" "$1" 2>/dev/null; }

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }
# The data plane says for itself whether a class can be walked: the "classes"
# entry carries enumerable true/false. Read that. Matching on the word
# "dpa_objects" is not evidence of anything -- a class with no walker answers
# with the same envelope and an empty object list.
probe() {
    local name=$1 cmd=$2 out rc
    out=$(S "$cmd"); rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
        printf '%s\tunreadable\n' "$name"
        return
    fi
    printf '%s' "$out" | python3 -c '
import json, sys
name = sys.argv[1]
t = sys.stdin.read()
try:
    d = json.loads(t[t.index("{"):])["dpa_objects"]
    c = [x for x in d["classes"] if x["class"] == name][0]
    print("%s\t%s" % (name, "enumerable" if c["enumerable"] else "not_enumerable"))
except Exception:
    print("%s\tunreadable" % name)
' "$name"
}

mkdir -p "$(dirname "$OUT")"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
probe route "sudo /opt/vyatta/bin/vplsh -l -c 'dpa object show route'" >>"$tmp"
probe route6 "sudo /opt/vyatta/bin/vplsh -l -c 'dpa object show route6'" >>"$tmp"
probe mpls-route "sudo /opt/vyatta/bin/vplsh -l -c 'dpa object show mpls-route'" >>"$tmp"
probe mroute "sudo /opt/vyatta/bin/vplsh -l -c 'dpa object show mroute'" >>"$tmp"
probe mroute6 "sudo /opt/vyatta/bin/vplsh -l -c 'dpa object show mroute6'" >>"$tmp"
probe vrf "sudo /opt/vyatta/bin/vplsh -l -c 'dpa object show vrf'" >>"$tmp"
probe nexthop-group "sudo /opt/vyatta/bin/vplsh -l -c 'dpa object show nexthop-group'" >>"$tmp"
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
