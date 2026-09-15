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
echo "    default VRF only (the tool reads 'show ip route', not 'vrf all'):"
S $R1 "sudo python3 /tmp/dpa-drift.py 2>&1 | head -6" | sed 's/^/      /'
echo
echo "    the non-default VRF is not in the comparison at all, because the"
echo "    Desired side asks zebra for the default VRF only. That is a second"
echo "    gap and it is invisible in the numbers above: a VRF that is never"
echo "    compared never drifts."

echo
echo "===== 6. Clean up ====="
S $R1 "sudo vtysh -c 'configure terminal' -c 'no ip route 10.31.31.0/24 blackhole vrf vrfRED' 2>&1 | head -1" > /dev/null
cli $R1 "delete interfaces dataplane dp0s9 address 10.30.30.1/24" \
        "delete routing routing-instance RED" | tail -1 | sed 's/^/    /'
S $R1 "sudo rm -f /tmp/dpa-drift.py" > /dev/null
sleep 5
S $R1 "ip -br link show type vrf | wc -l" | tail -1 | sed 's/^/    vrf devices left: /'
