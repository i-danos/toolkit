#!/bin/bash
# Do the two sides call a non-default VRF the same thing?
#
# The drift comparison keys on the VRF name because the numbers turned out to
# be separate namespaces -- DANOS's default VRF is 1 and zebra's is 0, and for
# non-default ones the two numbers have nothing to do with each other. Names
# fixed it, and 5 of 5 was measured on a box that had only the default VRF.
#
# Which means the name half was never tested. The data plane fills v_name from
# a "vrfX" interface with the first three characters stripped, so a routing
# instance called RED becomes "RED". zebra sees the Linux VRF device, whose
# name is whatever DANOS gave it -- quite possibly "vrfRED". If those disagree
# then every route in a non-default VRF is "desired but not programmed", which
# is the same catastrophic-looking report the numbers produced.
#
# The key-space guard would catch it, as it did before, so this is not about
# safety. It is about not shipping a comparison that is known to work on
# exactly one VRF and untested on every other.
#
# TOPO=ipsec. R1 gets a routing instance and a route in it; both are removed.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-/home/aikon/danos/.obs/probe-vrf-name-agreement.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.155

exec > "$OUT" 2>&1
"$HERE/image-fingerprint.sh"
S() { docker exec danos-robot timeout 180 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$1" "$2" 2>&1; }

cli() {
	local h=$1; shift
	local c=""
	for x in "$@"; do c="$c vcli -s \$SID -c \"$x\" 2>&1;"; done
	S "$h" "SID=\$\$; eval \"\$(cli-shell-api getSessionEnv \$SID)\"; cli-shell-api setupSession; $c
	        vcli -s \$SID -c commit 2>&1 | grep -viE 'sssd|configuration db|grub|boot-loader|crash dump|^\s*\$'"
}

echo "===== 1. Create a routing instance with a route in it ====="
cli $R1 "set routing routing-instance RED" \
        "set routing routing-instance RED interface dp0s9" \
        "set interfaces dataplane dp0s9 address 10.30.30.1/24" | tail -2 | sed 's/^/    /'
sleep 12
S $R1 "sudo vtysh -c 'configure terminal' -c 'ip route 10.31.31.0/24 blackhole vrf vrfRED' 2>&1 | head -2" | sed 's/^/    /'
sleep 6

echo
echo "===== 2. What the kernel calls it ====="
S $R1 "ip -br link show type vrf" | sed 's/^/    /'

echo
echo "===== 3. What zebra calls it ====="
S $R1 "sudo vtysh -c 'show vrf' 2>&1 | head -5" | sed 's/^/    /'
echo "    and in the route JSON:"
S $R1 "sudo vtysh -c 'show ip route vrf all json' 2>/dev/null | python3 -c 'import sys,json
d=json.load(sys.stdin)
names=set()
def walk(o):
    if isinstance(o, dict):
        for k,v in o.items():
            if k==\"vrfName\": names.add(v)
            walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
walk(d)
print(sorted(names))' 2>/dev/null" | tail -1 | sed 's/^/      /'

echo
echo "===== 4. What the data plane calls it ====="
S $R1 "sudo /opt/vyatta/bin/vplsh -l -c 'dpa object show route' 2>/dev/null | python3 -c 'import sys,json
seen=set()
for o in json.load(sys.stdin)[\"dpa_objects\"][\"objects\"]:
    seen.add(o[\"key\"].split(\"/\")[0])
print(sorted(seen))' 2>/dev/null" | tail -1 | sed 's/^/    /'

echo
echo "===== 5. Do they agree? ====="
b64=$(base64 -w0 "$HERE/dpa-drift.py")
S $R1 "echo '$b64' | base64 -d | sudo tee /tmp/dpa-drift.py >/dev/null; sudo chmod 755 /tmp/dpa-drift.py"
S $R1 "sudo python3 /tmp/dpa-drift.py 2>&1 | head -8" | sed 's/^/      /'
echo
# This used to print, under the output above, that the non-default VRF was not
# in the comparison at all because the Desired side read the default VRF alone.
# That was true when it was written and stopped being true when dpa-drift.py
# moved to "show ip route vrf all json", and the paragraph stayed. It was a
# statement about the tool printed next to output from the tool that contradicted
# it -- desired 8, matched 8, nothing missing on either side, with vrfRED named
# on both.
#
# So assert it rather than narrate it. A sentence cannot go stale if the run
# fails when it stops being true.
echo "    Assertions:"
rc=0
json=$(S $R1 "sudo python3 /tmp/dpa-drift.py --json 2>/dev/null" | tail -1)
check() { # check <label> <python-expression-on-d>
	if printf '%s' "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if ($2) else 1)" 2>/dev/null; then
		printf '      PASS  %s\n' "$1"
	else
		printf '      FAIL  %s\n' "$1"; rc=1
	fi
}
# The name the data plane uses for the non-default VRF has to be the one the
# kernel and zebra use, or every route in it compares as missing.
check "the data plane names the VRF vrfRED, not RED" \
      "any(e.get('vrf') == 'vrfRED' for e in d['dataplane_owned'])"
check "nothing still calls it RED" \
      "not any(e.get('vrf') == 'RED' for e in d['dataplane_owned'] + d['programmed_not_desired'])"
check "nothing desired is unprogrammed" "len(d['desired_not_programmed']) == 0"
check "nothing programmed is undesired" "len(d['programmed_not_desired']) == 0"
check "the key spaces line up" "d['keyspace_mismatch'] is False"
check "every desired route matched" "d['matched'] == d['desired'] and d['desired'] > 0"
[ "$rc" -eq 0 ] \
	&& echo "    NAMES AGREE across kernel, zebra and the data plane." \
	|| echo "    NAMES DO NOT AGREE -- see the failures above."

echo
echo "===== 6. Clean up ====="
S $R1 "sudo vtysh -c 'configure terminal' -c 'no ip route 10.31.31.0/24 blackhole vrf vrfRED' 2>&1 | head -1" > /dev/null
cli $R1 "delete interfaces dataplane dp0s9 address 10.30.30.1/24" \
        "delete routing routing-instance RED" | tail -1 | sed 's/^/    /'
S $R1 "sudo rm -f /tmp/dpa-drift.py" > /dev/null
sleep 5
S $R1 "ip -br link show type vrf | wc -l" | tail -1 | sed 's/^/    vrf devices left: /'
