#!/bin/bash
# What would ARP suppression have to build, and what is already there?
#
# Suppression means a leaf answers an ARP for a remote host from what EVPN
# told it, instead of flooding the request across the fabric. Linux does this
# with neigh_suppress on the kernel bridge port, which is no use here: the
# bridge is in the dataplane and the kernel one carries no traffic.
#
# So the work splits in two, and only measurement says which halves are left:
#
#   the information   does zebra install the EVPN-learned host as a neighbour
#                     on the SVI, and does that reach the dataplane's own
#                     neighbour table?
#   the behaviour     does anything intercept an ARP request on a bridge and
#                     answer it? (No: bridge.c treats ARP as ordinary
#                     broadcast, touching it only to bypass the firewall.)
#
# If the information is already in the dataplane, suppression is a knob and a
# reply path. If it is not, it is a knob, a table, the netlink plumbing to
# fill it, and a reply path -- a different size of job.
#
# One detail worth checking rather than assuming: lladdr_add() translates
# NTF_PROXY into LLE_PROXY and ignores NTF_EXT_LEARNED, which is the same
# shape as the VXLAN defect fixed earlier this week -- a control-plane marker
# the dataplane drops. Whether it matters here depends on what zebra sets.
#
#   R1  VTEP 10.60.60.1   br10 10.10.10.1/24 (tun10), br20 10.20.20.1/24 (tun20), both RED
#   R2  VTEP 10.60.60.2   br10 10.10.10.2/24 (tun10), br20 10.20.20.2/24 (tun20 + dp0s8)
#   R3  host 10.20.20.3/24 on dp0s8
#
# R2's br20 address is the point, not scenery. Only a leaf with an SVI in the
# host's subnet learns the host's IP-to-MAC binding; a pure L2 leaf sees the
# MAC alone and advertises a MAC-only type-2 route. The first version of this
# probe left br20 addressless on R2, so nothing in the fabric knew the binding
# except R1, which had resolved it by ARPing -- the very thing suppression is
# meant to avoid. EVPN reported the entry as "local" on R1 and flushing it
# brought nothing back, which reads like zebra declining to publish when in
# fact nobody had anything to publish. Real deployments give every leaf an SVI
# in every subnet it serves, which is what makes the binding available to
# advertise in the first place.
#
# TOPO=ipsec wiring: R1.dp0s9 <-> R2.dp0s3, R2.dp0s8 <-> R3.dp0s8.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/probe-arp-suppression.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.155
R2=192.168.203.156
R3=192.168.203.157

exec > "$OUT" 2>&1
S() { docker exec danos-robot timeout 200 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$1" "$2" 2>&1; }

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
	cli $R2 "delete protocols bgp 65000" \
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

echo "===== 1. IRB topology with EVPN ====="
cli $R1 "set interfaces dataplane dp0s9 address 10.60.60.1/24" \
        "set interfaces tunnel tun10 encapsulation vxlan" "set interfaces tunnel tun10 vxlan-id 10" \
        "set interfaces tunnel tun10 local-ip 10.60.60.1" "set interfaces tunnel tun10 remote-ip 10.60.60.2" \
        "set interfaces tunnel tun20 encapsulation vxlan" "set interfaces tunnel tun20 vxlan-id 20" \
        "set interfaces tunnel tun20 local-ip 10.60.60.1" "set interfaces tunnel tun20 remote-ip 10.60.60.2" \
        "set interfaces bridge br10" "set interfaces bridge br10 address 10.10.10.1/24" \
        "set interfaces bridge br20" "set interfaces bridge br20 address 10.20.20.1/24" \
        "set interfaces tunnel tun10 bridge-group bridge br10" \
        "set interfaces tunnel tun20 bridge-group bridge br20" \
        "set routing routing-instance RED" \
        "set routing routing-instance RED interface br10" \
        "set routing routing-instance RED interface br20" \
        "set protocols bgp 65000 neighbor 10.60.60.2 remote-as 65000" \
        "set protocols bgp 65000 neighbor 10.60.60.2 update-source 10.60.60.1" \
        "set protocols bgp 65000 neighbor 10.60.60.2 address-family l2vpn-evpn" \
        "set protocols bgp 65000 address-family l2vpn-evpn advertise-all-vni" | tail -2
cli $R2 "set interfaces dataplane dp0s3 address 10.60.60.2/24" \
        "set interfaces tunnel tun10 encapsulation vxlan" "set interfaces tunnel tun10 vxlan-id 10" \
        "set interfaces tunnel tun10 local-ip 10.60.60.2" "set interfaces tunnel tun10 remote-ip 10.60.60.1" \
        "set interfaces tunnel tun20 encapsulation vxlan" "set interfaces tunnel tun20 vxlan-id 20" \
        "set interfaces tunnel tun20 local-ip 10.60.60.2" "set interfaces tunnel tun20 remote-ip 10.60.60.1" \
        "set interfaces bridge br10" "set interfaces bridge br10 address 10.10.10.2/24" \
        "set interfaces bridge br20" "set interfaces bridge br20 address 10.20.20.2/24" \
        "set interfaces tunnel tun10 bridge-group bridge br10" \
        "set interfaces tunnel tun20 bridge-group bridge br20" \
        "set interfaces dataplane dp0s8 bridge-group bridge br20" \
        "set protocols bgp 65000 neighbor 10.60.60.1 remote-as 65000" \
        "set protocols bgp 65000 neighbor 10.60.60.1 update-source 10.60.60.2" \
        "set protocols bgp 65000 neighbor 10.60.60.1 address-family l2vpn-evpn" \
        "set protocols bgp 65000 address-family l2vpn-evpn advertise-all-vni" | tail -2
cli $R3 "set interfaces dataplane dp0s8 address 10.20.20.3/24" \
        "set protocols static route 10.10.10.0/24 next-hop 10.20.20.1" | tail -2
sleep 50

echo
echo "===== 2. Make R2 learn and advertise the host ====="
S $R2 "ping -c 3 -W 2 10.20.20.3 >/dev/null 2>&1"
sleep 20
echo "  R1's EVPN view of VNI 20:"
S $R1 'sudo vtysh -c "show evpn arp-cache vni 20" 2>&1 | tail -4' | sed 's/^/    /'

echo
echo "===== 3. Forget it locally, then see what puts it back ====="
# R1 has probably ARPed for the host itself. Flushing separates "R1 resolved
# it" from "EVPN told R1", which is the whole question.
S $R1 "sudo ip neigh flush dev br20 2>/dev/null; sudo ip -4 neigh del 10.20.20.3 dev br20 2>/dev/null; echo flushed" | tail -1 | sed 's/^/  /'
sleep 25
echo "  kernel, br20 -- an extern_learn entry here came from EVPN, not from ARP:"
S $R1 "sudo ip neigh show dev br20 2>/dev/null | sed 's/^/    /'" | tail -5
echo "  kernel, vrfRED:"
S $R1 "sudo ip neigh show vrf vrfRED 2>/dev/null | grep -E '10\.20\.20' | sed 's/^/    /'" | tail -3

echo
echo "===== 4. Does the dataplane hold it ====="
for c in "arp show" "arp"; do
	echo "  vplsh '$c':"
	S $R1 "sudo /opt/vyatta/bin/vplsh -l -c '$c' 2>&1 | head -25" | sed 's/^/    /'
done

echo
echo "===== 5. Is an ARP for it still flooded ====="
echo "  tun20 statistics keys, so the counter below is known to exist:"
S $R1 "sudo /opt/vyatta/bin/vplsh -l -c 'ifconfig tun20' 2>/dev/null | python3 -c \"
import sys,json
d=json.load(sys.stdin)
for i in d.get('interfaces',[]):
    print('   ', i.get('name'), sorted(i.get('statistics',{}))[:12])
\" 2>/dev/null" | tail -2
before=$(S $R1 "sudo /opt/vyatta/bin/vplsh -l -c 'ifconfig tun20' 2>/dev/null | python3 -c \"
import sys,json
d=json.load(sys.stdin)
for i in d.get('interfaces',[]):
    s=i.get('statistics',{}); print(s.get('tx_packets','?'))
\" 2>/dev/null" | tail -1)
S $R1 "sudo ip -4 neigh del 10.20.20.3 dev br20 2>/dev/null; sudo ip vrf exec vrfRED ping -c 2 -W 2 -I 10.20.20.1 10.20.20.3 >/dev/null 2>&1"
sleep 3
after=$(S $R1 "sudo /opt/vyatta/bin/vplsh -l -c 'ifconfig tun20' 2>/dev/null | python3 -c \"
import sys,json
d=json.load(sys.stdin)
for i in d.get('interfaces',[]):
    s=i.get('statistics',{}); print(s.get('tx_packets','?'))
\" 2>/dev/null" | tail -1)
printf '  tun20 tx_packets across a fresh resolve: %s -> %s\n' "${before:-?}" "${after:-?}"
echo "  (with suppression that difference should be the data only, not the ARP)"

echo
echo "===== 6. Reading ====="
echo "  Step 3 decides the size of the job. An extern_learn entry for"
echo "  10.20.20.3 that reappears without R1 ARPing means zebra already"
echo "  publishes what suppression needs, and step 4 says whether the"
echo "  dataplane already receives it."
echo
echo "  If both hold, ARP suppression is a config knob plus an intercept in"
echo "  bridge_input that answers from the SVI's neighbour table. If step 4"
echo "  is empty, the netlink plumbing has to be written too."

cleanup
