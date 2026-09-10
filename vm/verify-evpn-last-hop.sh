#!/bin/bash
# Does a MAC learned by BGP EVPN reach the dataplane's forwarding table?
#
# The viability run established the three pieces separately: VXLAN forwards in
# bridge mode (ping 4/4), bgpd accepts the l2vpn evpn address family, and zebra
# picks up the VNI from a DANOS VXLAN interface on its own -- "100 L2 tun0".
#
# What none of that shows is the join. FRR programs a remote MAC by writing a
# bridge FDB entry on the VXLAN device with NDA_DST set to the remote VTEP, and
# the dataplane already has a handler for exactly that message shape:
#
#   bridge.c:1929   if (ifp->if_type == IFT_VXLAN && vxlan_get_vni(ifp))
#                           skip = vxlan_neigh_change(nlh, ndm, tb);
#
# If a MAC advertised by the far side lands in the dataplane, then EVPN-VXLAN
# needs no new forwarding code here and is a far cheaper L2VPN than VPLS, which
# has none of these three pieces. If it stops at the kernel, the gap is one
# netlink handler and that is still cheaper than VPLS. Either answer decides
# the next block of work, which is why it is worth twenty minutes.
#
#   R1  VTEP 10.60.60.1, br0 10.61.61.1/24, tun0 vni 100, AS 65001
#   R2  VTEP 10.60.60.2, br0 10.61.61.2/24, tun0 vni 100, AS 65002
#
# TOPO=ipsec wiring: R1.dp0s9 <-> R2.dp0s3.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-evpn-last-hop.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.155
R2=192.168.203.156

exec > "$OUT" 2>&1
S() { docker exec danos-robot timeout 200 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$1" "$2" 2>&1; }

cli() {
	local h=$1; shift
	local c=""
	for x in "$@"; do c="$c vcli -s \$SID -c \"$x\" 2>&1;"; done
	S "$h" "SID=\$\$; eval \"\$(cli-shell-api getSessionEnv \$SID)\"; cli-shell-api setupSession; $c
	        vcli -s \$SID -c commit 2>&1 | grep -viE 'sssd|configuration db|grub|boot-loader|crash dump|^\s*\$' | tail -2"
}

setup_vtep() {   # host local remote braddr
	cli "$1" "set interfaces dataplane $5 address $2/24" \
	         "set interfaces tunnel tun0 encapsulation vxlan" \
	         "set interfaces tunnel tun0 vxlan-id 100" \
	         "set interfaces tunnel tun0 local-ip $2" \
	         "set interfaces tunnel tun0 remote-ip $3" \
	         "set interfaces bridge br0" \
	         "set interfaces bridge br0 address $4/24" \
	         "set interfaces tunnel tun0 bridge-group bridge br0" > /dev/null
}

echo "===== 1. Two VTEPs, VNI 100 ====="
setup_vtep $R1 10.60.60.1 10.60.60.2 10.61.61.1 dp0s9
setup_vtep $R2 10.60.60.2 10.60.60.1 10.61.61.2 dp0s3
sleep 10
S $R1 "ping -c 2 -W 2 10.61.61.2 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | sed 's/^/  overlay reachable: /'

echo; echo "===== 2. BGP EVPN between the VTEPs ====="
S $R1 'sudo vtysh -c "configure terminal" \
  -c "router bgp 65001" -c "neighbor 10.60.60.2 remote-as 65002" \
  -c "address-family l2vpn evpn" -c "neighbor 10.60.60.2 activate" -c "advertise-all-vni" \
  -c "end" >/dev/null 2>&1; echo "  R1 configured"' | tail -1
S $R2 'sudo vtysh -c "configure terminal" \
  -c "router bgp 65002" -c "neighbor 10.60.60.1 remote-as 65001" \
  -c "address-family l2vpn evpn" -c "neighbor 10.60.60.1 activate" -c "advertise-all-vni" \
  -c "end" >/dev/null 2>&1; echo "  R2 configured"' | tail -1
sleep 35

echo; echo "===== 3. Is the session up? ====="
S $R1 'sudo vtysh -c "show bgp l2vpn evpn summary" 2>&1 | tail -6 | sed "s/^/    /"' | tail -6

echo; echo "===== 4. Are there type-2 routes? ====="
S $R1 'echo "  local + received:"; sudo vtysh -c "show bgp l2vpn evpn" 2>&1 | tail -12 | sed "s/^/    /"' | tail -12

echo; echo "===== 5. What zebra made of them ====="
S $R1 'echo "  vni:"; sudo vtysh -c "show evpn vni" 2>&1 | tail -3 | sed "s/^/    /"
       echo "  macs:"; sudo vtysh -c "show evpn mac vni 100" 2>&1 | tail -8 | sed "s/^/    /"' | tail -12

echo; echo "===== 6. Did it reach the kernel FDB? ====="
S $R1 'echo "  bridge fdb on tun0 with a remote VTEP:"
       bridge fdb show dev tun0 2>/dev/null | grep -E "dst " | head -5 | sed "s/^/    /"
       printf "  count: %s\n" "$(bridge fdb show dev tun0 2>/dev/null | grep -c "dst ")"' | tail -8

echo; echo "===== 7. Did it reach the DATAPLANE? ====="
S $R1 'echo "  dataplane vxlan macs:"
       sudo /opt/vyatta/bin/vplsh -l -c "vxlan macs" 2>&1 | head -c 600; echo
       echo "  dataplane bridge macs:"
       sudo /opt/vyatta/bin/vplsh -l -c "bridge br0 macs show" 2>&1 | head -c 600; echo' | tail -8

echo; echo "===== 8. Verdict ====="
kfdb=$(S $R1 'bridge fdb show dev tun0 2>/dev/null | grep -c "dst "' | tail -1 | tr -dc '0-9')
dpm=$(S $R1 'sudo /opt/vyatta/bin/vplsh -l -c "vxlan macs" 2>&1 | grep -oE "([0-9a-f]{1,2}:){5}[0-9a-f]{1,2}" | wc -l' | tail -1 | tr -dc '0-9')
sess=$(S $R1 'sudo vtysh -c "show bgp l2vpn evpn summary" 2>&1 | grep -cE "Established|[0-9]+ +[0-9]+ +[0-9]+ +[0-9]+ +[0-9]+ +[0-9]+"' | tail -1 | tr -dc '0-9')
printf '  BGP EVPN session lines: %s   kernel FDB remote entries: %s   dataplane vxlan macs: %s\n' \
	"${sess:-?}" "${kfdb:-?}" "${dpm:-?}"
if [ "${sess:-0}" -eq 0 ]; then
	echo "  INCONCLUSIVE: no BGP EVPN session, so nothing could have been"
	echo "  advertised. Read section 3 before drawing any conclusion."
elif [ "${dpm:-0}" -gt 0 ]; then
	echo "  EVPN REACHES THE DATAPLANE. No new forwarding code is needed for"
	echo "  EVPN-VXLAN; it is a far cheaper L2VPN than VPLS."
elif [ "${kfdb:-0}" -gt 0 ]; then
	echo "  EVPN reaches the KERNEL but not the dataplane. The gap is the"
	echo "  netlink path into vxlan_neigh_change() -- one handler to debug,"
	echo "  still much less than VPLS from nothing."
else
	echo "  EVPN produced no remote MAC at all. Section 4 says whether the"
	echo "  routes were advertised; if they were, the gap is in zebra rather"
	echo "  than in the dataplane."
fi

echo; echo "===== 9. Clean up ====="
S $R1 'sudo vtysh -c "configure terminal" -c "no router bgp 65001" -c "end" >/dev/null 2>&1' > /dev/null
S $R2 'sudo vtysh -c "configure terminal" -c "no router bgp 65002" -c "end" >/dev/null 2>&1' > /dev/null
cli $R1 "delete interfaces tunnel tun0" "delete interfaces bridge br0" \
        "delete interfaces dataplane dp0s9 address 10.60.60.1/24" > /dev/null
cli $R2 "delete interfaces tunnel tun0" "delete interfaces bridge br0" \
        "delete interfaces dataplane dp0s3 address 10.60.60.2/24" > /dev/null
sleep 6
for h in $R1 $R2; do
	S "$h" 'printf "  tun0 gone: %s  br0 gone: %s  bgp gone: %s\n" \
	          "$(ip link show tun0 >/dev/null 2>&1 && echo no || echo yes)" \
	          "$(ip link show br0 >/dev/null 2>&1 && echo no || echo yes)" \
	          "$(sudo vtysh -c "show running-config" 2>/dev/null | grep -c "router bgp")"' | tail -1
done
