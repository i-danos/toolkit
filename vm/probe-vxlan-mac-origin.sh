#!/bin/bash
# Where does the entry that forwards actually come from?
#
# verify-evpn-forwarding.sh concluded that R1 forwards by the EVPN-learned MAC.
# Reading vxlan_output() afterwards raises a second candidate it did not
# exclude. Two paths can put a MAC in R1's VXLAN table:
#
#   netlink   vxlan_newneigh()  -- FRR programs it, flags = NUD state only
#   learning  vxlan_rtupdate()  -- a frame arrived over the tunnel, flags
#                                  carry IFBAF_ADDR_V4 and the source VTEP
#
# and vxlan_output() will only encapsulate when IFBAF_ADDR_V4 (or _V6) is set:
#
#	if (vxlrt->vxlrt_flags & IFBAF_ADDR_V4) { ... }
#	else if (vxlrt->vxlrt_flags & IFBAF_ADDR_V6) { ... }
#	else
#		goto drop;
#
# vxlan_newneigh() never sets either flag. If that reading is right, a purely
# EVPN-programmed MAC is dropped, not forwarded -- and the traffic in the
# earlier run was carried by an entry R1 learned from frames R2 flooded at it,
# which the test did not prevent.
#
# The two hypotheses differ in what the table says, so ask the table:
#
#   type "dynamic"           learned from the data path
#   type "local"/"static"    programmed by netlink
#   OUTDISCARDS climbing     vxlan_output() took the drop branch
#
# No rebuild: this runs on the image already installed and only reads.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/probe-vxlan-mac-origin.log}
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
	        vcli -s \$SID -c commit 2>&1 | grep -viE 'sssd|configuration db|grub|boot-loader|crash dump|^\s*\$' | tail -2"
}

dump_table() { S $R1 "sudo /opt/vyatta/bin/vplsh -l -c 'vxlan macs show' 2>&1" | sed 's/^/    /'; }
outdiscards() {
	S $R1 "sudo /opt/vyatta/bin/vplsh -l -c 'vxlan stats show' 2>/dev/null \
	       | python3 -c 'import sys,json; print(json.load(sys.stdin).get(\"OutDiscards\",\"?\"))' 2>/dev/null" \
	  | tail -1
}
ping_r3() {
	S $R1 "sudo ip neigh replace 10.61.61.3 lladdr $MAC3 dev br0 2>/dev/null
	       ping -c 3 -W 2 10.61.61.3 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | tr -dc '0-9'
}

echo "===== 1. Topology, R1's flood path dead as before ====="
cli $R1 "set interfaces dataplane dp0s9 address 10.60.60.1/24" \
        "set interfaces tunnel tun0 encapsulation vxlan" \
        "set interfaces tunnel tun0 vxlan-id 100" \
        "set interfaces tunnel tun0 local-ip 10.60.60.1" \
        "set interfaces tunnel tun0 remote-ip 10.60.60.99" \
        "set interfaces bridge br0" \
        "set interfaces bridge br0 address 10.61.61.1/24" \
        "set interfaces tunnel tun0 bridge-group bridge br0" > /dev/null
cli $R2 "set interfaces dataplane dp0s3 address 10.60.60.2/24" \
        "set interfaces tunnel tun0 encapsulation vxlan" \
        "set interfaces tunnel tun0 vxlan-id 100" \
        "set interfaces tunnel tun0 local-ip 10.60.60.2" \
        "set interfaces tunnel tun0 remote-ip 10.60.60.1" \
        "set interfaces bridge br0" \
        "set interfaces bridge br0 address 10.61.61.2/24" \
        "set interfaces tunnel tun0 bridge-group bridge br0" \
        "set interfaces dataplane dp0s8 bridge-group bridge br0" > /dev/null
cli $R3 "set interfaces dataplane dp0s8 address 10.61.61.3/24" > /dev/null
sleep 12
MAC3=$(S $R3 "cat /sys/class/net/dp0s8/address" | tail -1)
echo "  R3 dp0s8 MAC: $MAC3"

echo; echo "===== 2. R1's table with no EVPN and no traffic ====="
dump_table

echo; echo "===== 3. R2 pings R3. R2 floods toward R1; can R1 learn from that? ====="
S $R2 "ping -c 3 -W 2 10.61.61.3 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | sed 's/^/  R2 -> R3: /'
sleep 4
echo "  R1's table now -- any entry here arrived WITHOUT EVPN:"
dump_table

echo; echo "===== 4. Bring up EVPN ====="
S $R1 'sudo vtysh -c "configure terminal" -c "router bgp 65000" \
  -c "neighbor 10.60.60.2 remote-as 65000" -c "neighbor 10.60.60.2 update-source 10.60.60.1" \
  -c "address-family l2vpn evpn" -c "neighbor 10.60.60.2 activate" -c "advertise-all-vni" \
  -c "end" >/dev/null 2>&1; echo "  R1 configured"' | tail -1
S $R2 'sudo vtysh -c "configure terminal" -c "router bgp 65000" \
  -c "neighbor 10.60.60.1 remote-as 65000" -c "neighbor 10.60.60.1 update-source 10.60.60.2" \
  -c "address-family l2vpn evpn" -c "neighbor 10.60.60.1 activate" -c "advertise-all-vni" \
  -c "end" >/dev/null 2>&1; echo "  R2 configured"' | tail -1
sleep 45
echo "  R1 kernel FDB:"
S $R1 '/sbin/bridge fdb show dev tun0 2>/dev/null | grep "dst " | sed "s/^/    /"' | tail -3
echo "  R1's table with EVPN up:"
dump_table

echo; echo "===== 5. Ping, and watch the drop counter ====="
before=$(outdiscards)
echo "  OUTDISCARDS before: ${before:-?}"
got=$(ping_r3)
after=$(outdiscards)
echo "  R1 -> R3: ${got:-?} of 3"
echo "  OUTDISCARDS after:  ${after:-?}"
echo "  R1's table after the ping:"
dump_table

echo; echo "===== 6. Reading ====="
echo "  If step 3 already shows an entry, R1 learns this MAC from the data"
echo "  path and the earlier forwarding verdict does not hold as stated."
echo "  If OUTDISCARDS climbed by roughly the ping count, vxlan_output() is"
echo "  dropping on the missing IFBAF_ADDR_V4 and something else carried it."

echo; echo "===== 7. Clean up ====="
S $R1 'sudo vtysh -c "configure terminal" -c "no router bgp 65000" -c "end" >/dev/null 2>&1' > /dev/null
S $R2 'sudo vtysh -c "configure terminal" -c "no router bgp 65000" -c "end" >/dev/null 2>&1' > /dev/null
cli $R1 "delete interfaces tunnel tun0" "delete interfaces bridge br0" \
        "delete interfaces dataplane dp0s9 address 10.60.60.1/24" > /dev/null
cli $R2 "delete interfaces dataplane dp0s8 bridge-group" \
        "delete interfaces tunnel tun0" "delete interfaces bridge br0" \
        "delete interfaces dataplane dp0s3 address 10.60.60.2/24" > /dev/null
cli $R3 "delete interfaces dataplane dp0s8 address 10.61.61.3/24" > /dev/null
sleep 6
for h in $R1 $R2; do
	S "$h" 'printf "  tun0 gone: %s  br0 gone: %s  bgp gone: %s\n" \
	          "$(ip link show tun0 >/dev/null 2>&1 && echo no || echo yes)" \
	          "$(ip link show br0 >/dev/null 2>&1 && echo no || echo yes)" \
	          "$(sudo vtysh -c "show running-config" 2>/dev/null | grep -c "router bgp")"' | tail -1
done
