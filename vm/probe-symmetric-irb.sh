#!/bin/bash
# Is symmetric IRB a dataplane feature here, or a composition of existing ones?
#
# EVPN-IRB-ASYMMETRIC-FIRST.md says symmetric IRB "has nothing to build on",
# on the strength of l3vni, rmac and svi matching nothing in the dataplane
# source. That is evidence about vocabulary. The same reasoning said asymmetric
# IRB needed new work, and measuring found every piece already present.
#
# So take the datapath apart and ask which of its steps this platform lacks:
#
#   ingress   route in the tenant VRF, next hop is the far leaf's L3VNI SVI
#             resolve that next hop to the far leaf's router MAC  (ARP)
#             bridge the frame into the L3VNI                     (bridge + VXLAN)
#             encapsulate to the far VTEP                         (VXLAN)
#   egress    decapsulate, inner destination is our own SVI MAC   (bridge local)
#             route in the tenant VRF                             (SVI in VRF)
#             deliver to the tenant port
#
# Every step on the right is something already measured working. What FRR
# calls an L3VNI is then a bridge whose only member is a VXLAN tunnel and
# whose SVI is in the tenant VRF; what it calls a router MAC is that SVI's
# MAC, learned by ARP like any other. Nothing here is programmed by hand that
# a control plane could not program instead.
#
# The point of symmetric IRB is that a leaf carries only the VNIs it hosts.
# R1 has no VNI 20 in this topology and must still reach a host in it -- if
# that works, the transit VNI is doing its job.
#
#   R1  VTEP 10.60.60.1   br5  10.50.50.1/24 (tun5, VNI 5000)   transit
#                         br10 10.10.10.1/24                     tenant, local
#                         both in routing-instance RED
#   R2  VTEP 10.60.60.2   br5  10.50.50.2/24 (tun5, VNI 5000)   transit
#                         br20 10.20.20.1/24 (dp0s8)             tenant, local
#                         both in routing-instance RED
#   R3  host 10.20.20.3/24 on dp0s8
#
# Static routes stand in for the EVPN type-5 routes a control plane would
# install. That is the substitution this probe makes and the only one: the
# forwarding behaviour under test is identical either way, and FRR's ability
# to originate them is a separate question from the dataplane's ability to
# follow them.
#
# R1 sources from br10's own address, so the ingress bridging hop from a host
# is not covered. verify-asymmetric-irb.sh showed that hop working on the same
# machinery; this is a viability probe, not a conformance test.
#
# br10 still needs a member port. A bridge with none has no carrier, the
# kernel holds it down, and no connected route is installed -- so the source
# address does not exist and the ping fails for a reason that has nothing to
# do with what is being measured. This was written down in
# probe-irb-viability.sh after costing a run there, and cost another one here
# before being applied.
#
# TOPO=ipsec wiring: R1.dp0s9 <-> R2.dp0s3, R2.dp0s8 <-> R3.dp0s8.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/probe-symmetric-irb.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.155
R2=192.168.203.156
R3=192.168.203.157

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

cleanup() {
	echo; echo "===== Clean up ====="
	cli $R1 "delete routing routing-instance RED" \
	        "delete interfaces dataplane dp0s3 bridge-group" \
	        "delete interfaces tunnel tun5" \
	        "delete interfaces bridge br5" "delete interfaces bridge br10" \
	        "delete interfaces dataplane dp0s9 address 10.60.60.1/24" > /dev/null
	cli $R2 "delete routing routing-instance RED" \
	        "delete interfaces dataplane dp0s8 bridge-group" \
	        "delete interfaces tunnel tun5" \
	        "delete interfaces bridge br5" "delete interfaces bridge br20" \
	        "delete interfaces dataplane dp0s3 address 10.60.60.2/24" > /dev/null
	cli $R3 "delete interfaces dataplane dp0s8 address 10.20.20.3/24" \
	        "delete protocols static route 10.10.10.0/24" > /dev/null
	sleep 6
	for h in $R1 $R2; do
		S "$h" 'printf "  tun5 %s  br5 %s  RED %s\n" \
		          "$(ip link show tun5 >/dev/null 2>&1 && echo LEFT || echo gone)" \
		          "$(ip link show br5 >/dev/null 2>&1 && echo LEFT || echo gone)" \
		          "$(ip link show vrfRED >/dev/null 2>&1 && echo LEFT || echo gone)"' | tail -1
	done
}

echo "===== 1. A transit VNI and one tenant subnet on each leaf ====="
cli $R1 "set interfaces dataplane dp0s9 address 10.60.60.1/24" \
        "set interfaces tunnel tun5 encapsulation vxlan" \
        "set interfaces tunnel tun5 vxlan-id 5000" \
        "set interfaces tunnel tun5 local-ip 10.60.60.1" \
        "set interfaces tunnel tun5 remote-ip 10.60.60.2" \
        "set interfaces bridge br5" \
        "set interfaces bridge br5 address 10.50.50.1/24" \
        "set interfaces tunnel tun5 bridge-group bridge br5" \
        "set interfaces bridge br10" \
        "set interfaces bridge br10 address 10.10.10.1/24" \
        "set interfaces dataplane dp0s3 bridge-group bridge br10" \
        "set routing routing-instance RED" \
        "set routing routing-instance RED interface br5" \
        "set routing routing-instance RED interface br10" \
        "set routing routing-instance RED protocols static route 10.20.20.0/24 next-hop 10.50.50.2" | tail -2
cli $R2 "set interfaces dataplane dp0s3 address 10.60.60.2/24" \
        "set interfaces tunnel tun5 encapsulation vxlan" \
        "set interfaces tunnel tun5 vxlan-id 5000" \
        "set interfaces tunnel tun5 local-ip 10.60.60.2" \
        "set interfaces tunnel tun5 remote-ip 10.60.60.1" \
        "set interfaces bridge br5" \
        "set interfaces bridge br5 address 10.50.50.2/24" \
        "set interfaces tunnel tun5 bridge-group bridge br5" \
        "set interfaces bridge br20" \
        "set interfaces bridge br20 address 10.20.20.1/24" \
        "set interfaces dataplane dp0s8 bridge-group bridge br20" \
        "set routing routing-instance RED" \
        "set routing routing-instance RED interface br5" \
        "set routing routing-instance RED interface br20" \
        "set routing routing-instance RED protocols static route 10.10.10.0/24 next-hop 10.50.50.1" | tail -2
cli $R3 "set interfaces dataplane dp0s8 address 10.20.20.3/24" \
        "set protocols static route 10.10.10.0/24 next-hop 10.20.20.1" | tail -2
sleep 18

echo
echo "===== 2. R1 has no VNI 20, which is the point ====="
echo "  R1's bridges:"
S $R1 "ip -br link show type bridge 2>/dev/null | awk '{print \"    \", \$1, \$2}'" | tail -4
echo "  R1's routes in RED:"
op $R1 "show ip route routing-instance RED" | grep -E "^[CLS]" | sed 's/^/    /' | head -6

if ! S $R1 "ip -br link show br10" | grep -q "UP"; then
	echo "  STOP: br10 is down, so 10.10.10.0/24 is not in the table and the"
	echo "  source address for step 4 does not exist. Nothing below would be"
	echo "  measuring symmetric IRB."
	cleanup
	exit 1
fi

echo
echo "===== 3. The transit VNI carries the underlay hop ====="
r=$(S $R1 "sudo ip vrf exec vrfRED ping -c 3 -W 2 10.50.50.2 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | tr -dc '0-9')
printf '  R1 -> R2 across VNI 5000: %s of 3\n' "${r:-?}"
echo "  what R1 resolved for the far SVI -- this is the router MAC:"
S $R1 "sudo ip neigh show vrf vrfRED 2>/dev/null | grep '10\.50\.50\.2' | sed 's/^/    /'" | tail -1

echo
echo "===== 4. The whole path: routed at both ends, one transit VNI ====="
got=$(S $R1 "sudo ip vrf exec vrfRED ping -c 4 -W 3 -I 10.10.10.1 10.20.20.3 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | tr -dc '0-9')
printf '  R1 10.10.10.1 -> R3 10.20.20.3: %s of 4  %s\n' "${got:-?}" \
	"$([ "${got:-0}" -ge 3 ] && echo 'the symmetric IRB datapath works' || echo 'it does not')"

echo
echo "===== 5. It really went through the transit VNI ====="
# Two ways to be wrong here: R1 could have reached R3 by some other path, or
# the frames could have gone out untagged. The far leaf's own view settles it.
echo "  traceroute:"
S $R1 "sudo ip vrf exec vrfRED traceroute -n -w 2 -q 1 -m 4 -s 10.10.10.1 10.20.20.3 2>&1 | head -4" | sed 's/^/    /'
echo "  R2's bridge br5 MAC table -- R1's router MAC should be here, on tun5:"
S $R2 "sudo /opt/vyatta/bin/vplsh -l -c 'bridge br5 macs show' 2>/dev/null | head -c 600" | sed 's/^/    /'
echo
echo "  R2's VXLAN table for VNI 5000:"
S $R2 "sudo /opt/vyatta/bin/vplsh -l -c 'vxlan macs show' 2>/dev/null | head -c 600" | sed 's/^/    /'

echo
echo "===== 6. Reading ====="
echo "  If step 4 forwards, symmetric IRB is a composition of things this"
echo "  platform already has: a bridge whose only member is a VXLAN tunnel"
echo "  and whose SVI sits in the tenant VRF is what FRR calls an L3VNI, and"
echo "  that SVI's MAC, resolved by ordinary ARP, is what it calls the router"
echo "  MAC. The remaining work is then control plane -- FRR originating and"
echo "  installing type-5 routes with those next hops -- and not a dataplane"
echo "  feature."
echo
echo "  If step 4 does not forward, the step that failed says where to look."
echo "  Step 3 failing means the transit VNI itself is not carrying traffic,"
echo "  which is ordinary bridged VXLAN and would be a regression rather than"
echo "  a missing feature."
echo
echo "  Either way this does not test FRR. Static routes stand in for type-5"
echo "  routes; whether zebra can install one with a remote VTEP next hop is"
echo "  a separate question and the larger half of the remaining work."

cleanup
