#!/bin/bash
# Asymmetric IRB, every hop, including the one the probe could not reach.
#
# probe-asymmetric-irb.sh measured 4 of 4 but sourced the traffic from R1's
# own SVI, so the packet was already on the router that routes it. The hop it
# skipped is the first one: a packet arriving from another leaf, bridged into
# the ingress VNI, and only then routed. That is the hop where a bridge that
# is in a VRF for locally-originated traffic can still fail to route traffic
# that arrived over a tunnel, and "we did not test the first hop" is the shape
# of gap this project keeps finding.
#
# The ipsec topology has no spare port for a host behind R1, so R2 doubles as
# one. R2's br10 carries a host address in the default table with a static
# route to R1's SVI, which forces its traffic across VNI 10 to R1 rather than
# letting R2 shortcut to its own br20:
#
#   R2 br10 10.10.10.2      host in VNI 10, default table, route via 10.10.10.1
#     |  tun10, VNI 10
#   R1 br10 10.10.10.1      \ both in routing-instance RED: the only router
#   R1 br20 10.20.20.1      / that routes between the two bridge domains
#     |  tun20, VNI 20
#   R2 br20                 bridges to dp0s8
#   R3 10.20.20.3           host in VNI 20, route back via 10.20.20.1
#
# R2 holding a host address in one domain and bridging the other is artificial
# -- a leaf would not normally do both -- but every hop R1 performs is the
# real one, and R1 is what is under test.
#
# TOPO=ipsec wiring: R1.dp0s9 <-> R2.dp0s3, R2.dp0s8 <-> R3.dp0s8.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-asymmetric-irb.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.155
R2=192.168.203.156
R3=192.168.203.157
pass=0
fail=0

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

ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; shift; printf '%s\n' "$@" | head -8 | sed 's/^/        /'; fail=$((fail + 1)); }

check_contains() {
	local what=$1 want=$2 label=$3
	if printf '%s' "$what" | grep -qiE "$want"; then ok "$label"
	else bad "$label" "wanted to match: $want" "$what"; fi
}

cleanup() {
	echo; echo "===== Clean up ====="
	S $R1 'sudo vtysh -c "configure terminal" -c "no router bgp 65000" -c "end" >/dev/null 2>&1' > /dev/null
	S $R2 'sudo vtysh -c "configure terminal" -c "no router bgp 65000" -c "end" >/dev/null 2>&1' > /dev/null
	cli $R1 "delete protocols bgp 65000" "delete routing routing-instance RED" \
	        "delete interfaces tunnel tun10" "delete interfaces tunnel tun20" \
	        "delete interfaces bridge br10" "delete interfaces bridge br20" \
	        "delete interfaces dataplane dp0s9 address 10.60.60.1/24" > /dev/null
	cli $R2 "delete protocols bgp 65000" "delete protocols static route 10.20.20.0/24" \
	        "delete interfaces dataplane dp0s8 bridge-group" \
	        "delete interfaces tunnel tun10" "delete interfaces tunnel tun20" \
	        "delete interfaces bridge br10" "delete interfaces bridge br20" \
	        "delete interfaces dataplane dp0s3 address 10.60.60.2/24" > /dev/null
	cli $R3 "delete interfaces dataplane dp0s8 address 10.20.20.3/24" \
	        "delete protocols static route 10.10.10.0/24" > /dev/null
	sleep 6
	for h in $R1 $R2; do
		S "$h" 'printf "  tun10 %s  tun20 %s  br10 %s  br20 %s  RED %s  bgp %s\n" \
		          "$(ip link show tun10 >/dev/null 2>&1 && echo LEFT || echo gone)" \
		          "$(ip link show tun20 >/dev/null 2>&1 && echo LEFT || echo gone)" \
		          "$(ip link show br10 >/dev/null 2>&1 && echo LEFT || echo gone)" \
		          "$(ip link show br20 >/dev/null 2>&1 && echo LEFT || echo gone)" \
		          "$(ip link show vrfRED >/dev/null 2>&1 && echo LEFT || echo gone)" \
		          "$(sudo vtysh -c "show running-config" 2>/dev/null | grep -c "router bgp")"' | tail -1
	done
}

echo "===== 1. R1 is the only router between the two bridge domains ====="
cli $R1 "set interfaces dataplane dp0s9 address 10.60.60.1/24" \
        "set interfaces tunnel tun10 encapsulation vxlan" \
        "set interfaces tunnel tun10 vxlan-id 10" \
        "set interfaces tunnel tun10 local-ip 10.60.60.1" \
        "set interfaces tunnel tun10 remote-ip 10.60.60.2" \
        "set interfaces tunnel tun20 encapsulation vxlan" \
        "set interfaces tunnel tun20 vxlan-id 20" \
        "set interfaces tunnel tun20 local-ip 10.60.60.1" \
        "set interfaces tunnel tun20 remote-ip 10.60.60.2" \
        "set interfaces bridge br10" \
        "set interfaces bridge br10 address 10.10.10.1/24" \
        "set interfaces bridge br20" \
        "set interfaces bridge br20 address 10.20.20.1/24" \
        "set interfaces tunnel tun10 bridge-group bridge br10" \
        "set interfaces tunnel tun20 bridge-group bridge br20" \
        "set routing routing-instance RED" \
        "set routing routing-instance RED interface br10" \
        "set routing routing-instance RED interface br20" | tail -2
# R2 is a host in VNI 10 and a leaf for VNI 20. The static route is what stops
# it short-cutting to its own br20 and makes R1 do the routing.
cli $R2 "set interfaces dataplane dp0s3 address 10.60.60.2/24" \
        "set interfaces tunnel tun10 encapsulation vxlan" \
        "set interfaces tunnel tun10 vxlan-id 10" \
        "set interfaces tunnel tun10 local-ip 10.60.60.2" \
        "set interfaces tunnel tun10 remote-ip 10.60.60.1" \
        "set interfaces tunnel tun20 encapsulation vxlan" \
        "set interfaces tunnel tun20 vxlan-id 20" \
        "set interfaces tunnel tun20 local-ip 10.60.60.2" \
        "set interfaces tunnel tun20 remote-ip 10.60.60.1" \
        "set interfaces bridge br10" \
        "set interfaces bridge br10 address 10.10.10.2/24" \
        "set interfaces bridge br20" \
        "set interfaces tunnel tun10 bridge-group bridge br10" \
        "set interfaces tunnel tun20 bridge-group bridge br20" \
        "set interfaces dataplane dp0s8 bridge-group bridge br20" \
        "set protocols static route 10.20.20.0/24 next-hop 10.10.10.1" | tail -2
cli $R3 "set interfaces dataplane dp0s8 address 10.20.20.3/24" \
        "set protocols static route 10.10.10.0/24 next-hop 10.20.20.1" | tail -2
sleep 16

echo
echo "===== 2. The tenant VRF holds both domains and nothing else does ====="
red=$(op $R1 "show ip route routing-instance RED")
check_contains "$red" '10\.10\.10\.0/24 is directly connected, br10' "RED has VNI 10's subnet on br10"
check_contains "$red" '10\.20\.20\.0/24 is directly connected, br20' "RED has VNI 20's subnet on br20"
deflt=$(op $R1 "show ip route" | grep -E '10\.(10|20)\.(10|20)\.0/24' || true)
if [ -z "$(printf '%s' "$deflt" | tr -d '[:space:]')" ]; then
	ok "the default table has neither, so the tenant is isolated"
else
	bad "the default table has neither, so the tenant is isolated" "$deflt"
fi

echo
echo "===== 3. The full path, including the ingress bridging hop ====="
# R2 is the host here, so the packet reaches R1 over VNI 10 and has to be
# bridged in before anything routes it.
got=$(S $R2 "ping -c 4 -W 3 -I 10.10.10.2 10.20.20.3 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | tr -dc '0-9')
if [ "${got:-0}" -ge 3 ]; then
	ok "R2 10.10.10.2 -> R3 10.20.20.3 across the IRB: $got of 4"
else
	bad "R2 10.10.10.2 -> R3 10.20.20.3 across the IRB" "got $got of 4"
fi

echo
echo "===== 4. R1 really is the one routing it ====="
# If R2 had shortcut to its own br20 the traffic would never touch R1, and the
# ping above would pass while proving nothing about IRB.
hop=$(S $R2 "traceroute -n -w 2 -q 1 -m 4 10.20.20.3 2>&1 | head -4")
printf '%s\n' "$hop" | sed 's/^/    /'
check_contains "$hop" '10\.10\.10\.1' "the path goes through R1's VNI 10 SVI"
echo "  R1's ARP in RED, both sides:"
S $R1 "sudo ip neigh show vrf vrfRED 2>/dev/null | grep -E '10\.(10|20)\.' | sed 's/^/    /'" | tail -4

echo
echo "===== 5. With EVPN, what does the fabric know ====="
S $R1 'sudo vtysh -c "configure terminal" -c "router bgp 65000" \
  -c "neighbor 10.60.60.2 remote-as 65000" -c "neighbor 10.60.60.2 update-source 10.60.60.1" \
  -c "address-family l2vpn evpn" -c "neighbor 10.60.60.2 activate" -c "advertise-all-vni" \
  -c "end" >/dev/null 2>&1' > /dev/null
S $R2 'sudo vtysh -c "configure terminal" -c "router bgp 65000" \
  -c "neighbor 10.60.60.1 remote-as 65000" -c "neighbor 10.60.60.1 update-source 10.60.60.2" \
  -c "address-family l2vpn evpn" -c "neighbor 10.60.60.1 activate" -c "advertise-all-vni" \
  -c "end" >/dev/null 2>&1' > /dev/null
sleep 45
vnis=$(S $R1 'sudo vtysh -c "show evpn vni" 2>&1')
printf '%s\n' "$vnis" | head -5 | sed 's/^/    /'
check_contains "$vnis" '^10 +L2 +tun10 .*vrfRED' "zebra binds VNI 10 to the tenant VRF on its own"
check_contains "$vnis" '^20 +L2 +tun20 .*vrfRED' "zebra binds VNI 20 to the tenant VRF on its own"
arp=$(S $R1 'sudo vtysh -c "show evpn arp-cache vni 20" 2>&1')
printf '%s\n' "$arp" | tail -4 | sed 's/^/    /'
check_contains "$arp" '10\.20\.20\.3' "EVPN holds the far host's IP, which is what ARP suppression needs"

echo
echo "===== 6. Still forwarding with EVPN up ====="
got2=$(S $R2 "ping -c 4 -W 3 -I 10.10.10.2 10.20.20.3 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | tr -dc '0-9')
if [ "${got2:-0}" -ge 3 ]; then
	ok "the path survives EVPN being configured: $got2 of 4"
else
	bad "the path survives EVPN being configured" "got $got2 of 4"
fi

echo
echo "===== 7. Result ====="
printf '  %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
	echo "  ASYMMETRIC IRB WORKS ON THIS PLATFORM, with no dataplane change"
	echo "  and no new model: a bridge with an address, that bridge in a"
	echo "  routing instance, a VXLAN tunnel in the bridge, and the EVPN"
	echo "  address family. zebra derives the VNI-to-VRF binding itself."
else
	echo "  Something above did not hold. Check step 4 first: if the path"
	echo "  does not go through 10.10.10.1 then R2 short-cut to its own"
	echo "  br20, the ping proved nothing about IRB, and the static route"
	echo "  that prevents it is missing or wrong."
fi

cleanup
exit "$fail"
