#!/bin/bash
# How far is this platform from EVPN IRB, and which kind can it reach?
#
# Symmetric and asymmetric IRB need very different things, and the difference
# decides whether the next piece of work is modelling or a dataplane feature.
#
#   asymmetric   the ingress leaf routes between two bridge domains in a
#                tenant VRF and then bridges into the destination VNI. Every
#                leaf needs every VNI. Needs: a bridge with an address, that
#                bridge in a routing instance, and routing between two of them.
#
#   symmetric    the ingress leaf routes into a transit L3VNI, encapsulates to
#                the egress leaf's router MAC, and the egress leaf routes out
#                of it. Leaves need only the VNIs they host. Needs an L3VNI
#                concept, a router-MAC table, and a decapsulate-then-route
#                path -- none of which the dataplane has: l3vni, rmac and svi
#                match nothing in src/, and the FAL headers have no hooks.
#
# So the question worth measuring is the asymmetric one, because it is the one
# that might already be reachable. Three things have to hold, and each is
# checked on what the box reports rather than on whether a command succeeded:
#
#   1. a bridge with an address can be bound to a routing instance
#   2. its connected route lands in that instance's table, not the default one
#   3. traffic routes between two such bridges inside the instance
#
# Point 3 is the one that matters. The first two can both hold on a platform
# that still will not forward, which is the failure this project keeps finding.
#
# One router is enough: this asks what the platform can do, not what a fabric
# can do. Runs on whichever topology is booted; R is the router to use, and
# P1/P2 are two of its dataplane ports.
#
# The ports are not optional. A bridge with no member has no carrier, so the
# kernel holds it down and installs no connected route for it -- and the first
# version of this probe, which created the bridges empty, reported an empty
# routing instance and looked exactly like a platform where bridges are not
# VRF-aware. They are. Anything measured on a bridge has to have a member port
# in it first, or the measurement is about carrier.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/probe-irb-viability.log}
R=${R:-192.168.203.231}
P1=${P1:-dp0s3}
P2=${P2:-dp0s9}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

exec > "$OUT" 2>&1
S() { docker exec danos-robot timeout 200 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$1" "$2" 2>&1; }
op() { S "$1" "vbash -ic '$2' 2>&1" | grep -v '^vbash: '; }

cli() {
	local h=$1; shift
	local c=""
	for x in "$@"; do c="$c vcli -s \$SID -c \"$x\" 2>&1;"; done
	S "$h" "SID=\$\$; eval \"\$(cli-shell-api getSessionEnv \$SID)\"; cli-shell-api setupSession; $c
	        vcli -s \$SID -c commit 2>&1 | grep -viE 'sssd|configuration db|grub|boot-loader|crash dump|^\s*\$'"
}

echo "===== 1. Two bridges with addresses, both bound to one routing instance ====="
out=$(cli $R "set interfaces bridge br10" \
             "set interfaces bridge br10 address 10.10.10.1/24" \
             "set interfaces bridge br20" \
             "set interfaces bridge br20 address 10.20.20.1/24" \
             "set interfaces dataplane $P1 bridge-group bridge br10" \
             "set interfaces dataplane $P2 bridge-group bridge br20" \
             "set routing routing-instance RED" \
             "set routing routing-instance RED interface br10" \
             "set routing routing-instance RED interface br20")
if [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
	printf '%s\n' "$out" | sed 's/^/    /'
else
	echo "    committed with no output"
fi
sleep 8

echo
echo "===== 2. The bridges must be up, or the rest measures carrier ====="
S $R "ip -br link show br10; ip -br link show br20" | sed 's/^/    /' | tail -2

echo
echo "===== 3. Where did the connected routes go ====="
echo "  routing instance RED:"
red=$(op $R "show ip route routing-instance RED" )
printf '%s\n' "$red" | sed 's/^/    /' | head -14
echo "  default table:"
op $R "show ip route" | grep -E '10\.(10|20)\.' | sed 's/^/    /' | head -6

echo
echo "===== 4. Does the dataplane agree ====="
S $R "sudo /opt/vyatta/bin/vplsh -l -c 'route vrf' 2>/dev/null | head -20" | sed 's/^/    /'
echo "  bridge interfaces the dataplane holds:"
S $R "sudo /opt/vyatta/bin/vplsh -l -c 'ifconfig' 2>/dev/null | python3 -c \"
import sys, json
d = json.load(sys.stdin)
for i in d.get('interfaces', []):
    n = i.get('name','')
    if n.startswith('br'):
        print('    %s  vrf=%s  addrs=%s' % (n, i.get('vrf_id'),
              [a.get('inet') or a.get('inet6') for a in i.get('addresses', [])]))
\" 2>/dev/null" | tail -6

echo
echo "===== 5. Reading ====="
echo "  If RED holds both 10.10.10.0/24 and 10.20.20.0/24 as connected, and"
echo "  the default table holds neither, then a bridge is a first-class"
echo "  routing-instance member and asymmetric IRB is a modelling problem."
echo
echo "  If they stayed in the default table, the bridge is not VRF-aware and"
echo "  asymmetric IRB needs dataplane work too -- which would make both"
echo "  kinds of IRB dataplane projects rather than one of them."
echo
echo "  Either way symmetric IRB needs an L3VNI, a router-MAC table and a"
echo "  routed decapsulation path. None of those exist: l3vni, rmac and svi"
echo "  match nothing in the dataplane source, and the FAL headers carry no"
echo "  hooks for them. That is a feature, not a model."

echo
echo "===== 6. Clean up ====="
cli $R "delete routing routing-instance RED" \
       "delete interfaces dataplane $P1 bridge-group" \
       "delete interfaces dataplane $P2 bridge-group" \
       "delete interfaces bridge br10" \
       "delete interfaces bridge br20" > /dev/null
sleep 5
S $R 'printf "  br10 gone: %s  br20 gone: %s\n" \
        "$(ip link show br10 >/dev/null 2>&1 && echo no || echo yes)" \
        "$(ip link show br20 >/dev/null 2>&1 && echo no || echo yes)"' | tail -1
