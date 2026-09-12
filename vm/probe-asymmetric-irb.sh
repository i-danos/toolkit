#!/bin/bash
# Does the asymmetric IRB datapath already work here?
#
# probe-irb-viability.sh established the building block: a bridge with an
# address is a first-class routing-instance member, agreed on by FRR, the
# kernel and the dataplane. That is not the same as the datapath working, and
# the difference is the one this project keeps finding -- so measure it before
# modelling anything.
#
# Asymmetric IRB routes at the ingress leaf only. A packet from one bridge
# domain to a host in another is routed in the tenant VRF and then bridged
# into the destination VNI, so the egress leaf only ever bridges. The whole
# datapath is:
#
#   route in VRF RED, br10 -> br20      <- needs bridge-in-VRF, measured
#   ARP for the far host over VNI 20    <- needs flooding across VXLAN
#   bridge the unicast over VNI 20      <- needs VXLAN bridging, measured
#
# Every piece has been measured on its own. Whether they compose has not, and
# the middle one -- resolving a host that is not local, across a tunnel, from
# inside a VRF -- is where they are most likely not to.
#
#   R1  VTEP 10.60.60.1   br10 10.10.10.1/24 (tun10, VNI 10)
#                         br20 10.20.20.1/24 (tun20, VNI 20)   both in RED
#   R2  VTEP 10.60.60.2   br10 (tun10), br20 (tun20 + dp0s8)
#   R3  host 10.20.20.3/24 on dp0s8, route back via 10.20.20.1
#
# R1 sources from br10's own address, so the traffic starts in one bridge
# domain and ends in another on a different leaf. What that does not cover is
# a third box hanging off R1's br10: the ingress bridging hop. Everything
# after it is the same, and this is a viability probe, not a conformance test.
#
# TOPO=ipsec wiring: R1.dp0s9 <-> R2.dp0s3, R2.dp0s8 <-> R3.dp0s8.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/probe-asymmetric-irb.log}
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
	S $R1 'sudo vtysh -c "configure terminal" -c "no router bgp 65000" -c "end" >/dev/null 2>&1' > /dev/null
	S $R2 'sudo vtysh -c "configure terminal" -c "no router bgp 65000" -c "end" >/dev/null 2>&1' > /dev/null
	cli $R1 "delete protocols bgp 65000" "delete routing routing-instance RED" \
	        "delete interfaces tunnel tun10" "delete interfaces tunnel tun20" \
	        "delete interfaces bridge br10" "delete interfaces bridge br20" \
	        "delete interfaces dataplane dp0s9 address 10.60.60.1/24" > /dev/null
	cli $R2 "delete protocols bgp 65000" "delete interfaces dataplane dp0s8 bridge-group" \
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

echo "===== 1. Two bridge domains per leaf, both in tenant VRF RED ====="
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
        "set routing routing-instance RED interface br20" | tail -3
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
        "set interfaces bridge br20" \
        "set interfaces tunnel tun10 bridge-group bridge br10" \
        "set interfaces tunnel tun20 bridge-group bridge br20" \
        "set interfaces dataplane dp0s8 bridge-group bridge br20" | tail -3
cli $R3 "set interfaces dataplane dp0s8 address 10.20.20.3/24" \
        "set protocols static route 10.10.10.0/24 next-hop 10.20.20.1" | tail -2
sleep 14

echo
echo "===== 2. The bridges are up and in RED ====="
S $R1 "ip -br link show br10; ip -br link show br20" | grep -E "^br" | sed 's/^/    /'
op $R1 "show ip route routing-instance RED" | grep -E "^[CL]" | sed 's/^/    /'

echo
echo "===== 3. Route from one bridge domain to the other, in the VRF ====="
# Sourced from br10's address so the packet genuinely starts in VNI 10's
# domain and has to be routed into VNI 20's before anything is bridged.
got=$(S $R1 "sudo ip vrf exec vrfRED ping -c 4 -W 2 -I 10.10.10.1 10.20.20.3 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | tr -dc '0-9')
printf '  R1 10.10.10.1 -> R3 10.20.20.3: %s of 4  %s\n' "${got:-?}" \
	"$([ "${got:-0}" -ge 3 ] && echo 'the asymmetric IRB datapath works' || echo 'it does not')"

echo
echo "===== 4. What resolved the far host ====="
echo "  R1 ARP in RED:"
S $R1 "sudo ip neigh show vrf vrfRED 2>/dev/null | grep -i '10\.20\.20' | sed 's/^/    /'" | tail -3
echo "  R1 bridge br20 MAC table:"
S $R1 "sudo /opt/vyatta/bin/vplsh -l -c 'bridge br20 macs show' 2>/dev/null | head -14" | sed 's/^/    /'

echo
echo "===== 5. With EVPN, is the far MAC learned rather than flooded ====="
S $R1 'sudo vtysh -c "configure terminal" -c "router bgp 65000" \
  -c "neighbor 10.60.60.2 remote-as 65000" -c "neighbor 10.60.60.2 update-source 10.60.60.1" \
  -c "address-family l2vpn evpn" -c "neighbor 10.60.60.2 activate" -c "advertise-all-vni" \
  -c "end" >/dev/null 2>&1' > /dev/null
S $R2 'sudo vtysh -c "configure terminal" -c "router bgp 65000" \
  -c "neighbor 10.60.60.1 remote-as 65000" -c "neighbor 10.60.60.1 update-source 10.60.60.2" \
  -c "address-family l2vpn evpn" -c "neighbor 10.60.60.1 activate" -c "advertise-all-vni" \
  -c "end" >/dev/null 2>&1' > /dev/null
sleep 45
echo "  VNIs zebra found:"
S $R1 'sudo vtysh -c "show evpn vni" 2>&1 | head -6' | sed 's/^/    /'
echo "  MACs in VNI 20:"
S $R1 'sudo vtysh -c "show evpn mac vni 20" 2>&1 | tail -5' | sed 's/^/    /'
echo "  ARP cache EVPN holds for VNI 20 -- this is what ARP suppression needs:"
S $R1 'sudo vtysh -c "show evpn arp-cache vni 20" 2>&1 | tail -5' | sed 's/^/    /'

echo
echo "===== 6. Reading ====="
echo "  Step 3 is the verdict. If it forwards, asymmetric IRB is already a"
echo "  datapath this platform has, and the work left is a model for it plus"
echo "  whatever step 5 shows missing."
echo
echo "  Step 5 is about cost, not correctness. If EVPN holds the far host's"
echo "  IP as well as its MAC, ARP suppression has the information it needs"
echo "  and every leaf can answer locally instead of flooding an ARP across"
echo "  the fabric. If it holds only MACs, that is a separate piece of work"
echo "  and asymmetric IRB still functions without it, more noisily."

cleanup
