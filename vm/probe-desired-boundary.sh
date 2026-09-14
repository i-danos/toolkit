#!/bin/bash
# Where is the boundary a reconciliation loop would actually work across?
#
# The DPA object model can now say what the data plane holds and which backend
# has it. The other half -- what was *asked for* -- has no source yet, and the
# obvious answer looks wrong, which is why this exists before any of it is
# built.
#
# The assumption was that routes reach the data plane over FPM, because
# daemons.danos starts zebra with "-M dplane_fpm_nl". Nothing in the tree
# listens for FPM: the only hits are a small-form-factor-pluggable file and a
# SIP parser. Routes arrive by netlink, in ip_netlink.c, so the data plane's
# upstream should be the kernel FIB rather than zebra's RIB.
#
# If that holds on a running box then there are two drift boundaries, not one,
# and they belong to different owners:
#
#   zebra RIB  <->  kernel FIB     FRR's own; visible as "show ip route"
#                                  against "ip route", needs nothing from here
#   kernel FIB <->  dataplane LPM  the one the DPA owns, and the one a
#                                  reconciliation loop would drive
#
# The second is comparable from outside today with no new plumbing: "ip route"
# on one side, the DPA object view on the other, both already readable. Worth
# establishing before designing a way to read zebra from inside the data plane,
# which is what the earlier plan assumed would be needed.
#
# TOPO=ipsec. Only R1 is touched, and only read from apart from one route that
# is added and removed again.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-/home/aikon/danos/.obs/probe-desired-boundary.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.155

exec > "$OUT" 2>&1
"$HERE/image-fingerprint.sh"
S() { docker exec danos-robot timeout 120 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$1" "$2" 2>&1; }

VPLSH="sudo /opt/vyatta/bin/vplsh -l -c"

# "dpa object show" is newer than some images this has to run on. Where it is
# absent, fall back to the pd view, which carries the same prefixes in a
# different shape.
#
# Detected, never assumed. A probe that reported an empty route list because
# the command was not there would answer the central question of this file
# backwards -- and "the data plane holds nothing" is exactly the shape of a
# wrong answer that reads like a finding.
VIEW=none
detect_view() {
	if S $R1 "$VPLSH 'dpa object show route' 2>&1" | grep -q dpa_objects; then
		VIEW=dpa
	elif S $R1 "$VPLSH 'pd show dataplane route full' 2>&1" | grep -q objects; then
		VIEW=pd
	fi
	echo "    route view on this image: $VIEW"
	if [ "$VIEW" = none ]; then
		echo "    (no view: steps 3-6 cannot answer anything)"
	fi
}

# What the data plane holds, one line per route, whichever view exists.
dp_routes() {
	if [ "$VIEW" = dpa ]; then
		S $R1 "$VPLSH 'dpa object show route' 2>/dev/null | python3 -c 'import sys,json
for o in json.load(sys.stdin)[\"dpa_objects\"][\"objects\"]:
    print(o[\"key\"], o[\"state\"], o[\"backend\"])' 2>/dev/null"
	elif [ "$VIEW" = pd ]; then
		S $R1 "$VPLSH 'pd show dataplane route full' 2>/dev/null | python3 -c 'import sys,json
for o in json.load(sys.stdin)[\"objects\"]:
    if \"prefix\" in o: print(o[\"prefix\"])' 2>/dev/null"
	else
		echo "NO VIEW"
	fi
}

echo "===== 1. zebra is started with the FPM module ====="
S $R1 "grep -hE '^zebra_options' /etc/frr/daemons /etc/frr/daemons.danos 2>/dev/null | head -2" | sed 's/^/    /'

echo
echo "===== 2. Does anything listen for it? ====="
# zebra's dplane_fpm_nl is a *client*: it connects out to 2620 and retries
# forever if nothing is there, without saying so.
echo "    listening on 2620:"
S $R1 "sudo ss -ltn 2>/dev/null | grep 2620 || echo nothing" | sed 's/^/      /'
echo "    zebra's outbound attempts:"
S $R1 "sudo ss -tn state all 2>/dev/null | grep 2620 || echo none" | sed 's/^/      /'

echo
detect_view

echo
echo "===== 3. So how does a route reach the data plane? ====="
# Put one in the kernel and see whether it turns up. If it does, the path is
# netlink and the upstream is the kernel FIB.
S $R1 "sudo ip route replace 10.99.99.0/24 dev lo 2>&1; echo added" | tail -1 | sed 's/^/    /'
sleep 3
echo "    kernel:"
S $R1 "ip route show 10.99.99.0/24" | sed 's/^/      /'
echo "    dataplane:"
dp_routes | grep 10.99.99 | sed 's/^/      /' || echo "      NOT PRESENT"

echo
echo "===== 4. Do the two sides use comparable identities? ====="
# The DPA key was built to be compared -- external VRF id, table id, prefix.
# Here is where that claim meets what the kernel actually prints.
echo "    kernel:"
S $R1 "ip route show table main | head -5" | sed 's/^/      /'
echo "    dataplane:"
dp_routes | head -5 | sed 's/^/      /'

echo
echo "===== 5. Counts, both sides ====="
printf '    kernel main-table routes: %s\n' "$(S $R1 'ip -4 route show table main | wc -l' | tail -1)"
printf '    dataplane route objects:  %s\n' "$(dp_routes | grep -c .)"

echo
echo "===== 6. Does the data plane let go when the kernel does? ====="
# If both sides move together there is no drift here in steady state -- which
# is a finding, not a disappointment. It would say the netlink path is reliable
# and that a reconciliation loop earns its keep in the cases where it is not,
# rather than by watching a boundary that never slips.
S $R1 "sudo ip route del 10.99.99.0/24 dev lo 2>&1; echo removed" | tail -1 | sed 's/^/    /'
sleep 3
echo "    dataplane after removal:"
dp_routes | grep 10.99.99 | sed 's/^/      /' || echo "      gone, as the kernel is"

echo
echo "===== 7. What FRR thinks, for contrast ====="
S $R1 "sudo vtysh -c 'show ip route summary' 2>&1 | head -8" | sed 's/^/    /'
