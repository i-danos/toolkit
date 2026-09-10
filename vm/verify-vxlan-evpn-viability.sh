#!/bin/bash
# Is EVPN-VXLAN a plausible alternative to VPLS on this dataplane?
#
# The roadmap has VPLS/VPWS as the remaining L2VPN item. EVPN-VXLAN is its
# modern replacement, and reading the tree suggests far more of it is already
# here than of VPLS:
#
#   src/if/vxlan.c                     2167 lines
#   bridge netlink -> vxlan_neigh_change()   handles RTM_NEWNEIGH with NDA_DST,
#                                            which is exactly how FRR's EVPN
#                                            programs a remote MAC
#   FRR 10.3 bgpd                      ships EVPN
#   "vpls", "pseudowire", "evpn"       0 hits in the dataplane
#
# Reading is not running. This asks two questions in order, because the second
# is moot if the first fails:
#
#   1. Does a VXLAN tunnel forward at all between two routers?
#   2. Does bgpd bring up an EVPN session, and does anything reach zebra?
#
#   R1 dp0s9 10.60.60.1/24  ----  10.60.60.2/24 dp0s3 R2
#      tun0 vni 100, 10.61.61.1/24        tun0 vni 100, 10.61.61.2/24
#
# The interface has to be called tunN. Naming it vxl0 the first time made every
# set fail validation, the tunnel was never created, and the script duly
# reported "VXLAN does not forward" -- a verdict about a typo, phrased as a
# finding about the dataplane.
#
# TOPO=ipsec wiring: R1.dp0s9 <-> R2.dp0s3.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-vxlan-evpn.log}
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
	        vcli -s \$SID -c commit 2>&1 | grep -viE 'sssd|configuration db|grub|boot-loader|crash dump|^\s*\$' | tail -3"
}

echo "===== 1. Underlay ====="
cli $R1 "set interfaces dataplane dp0s9 address 10.60.60.1/24" > /dev/null
cli $R2 "set interfaces dataplane dp0s3 address 10.60.60.2/24" > /dev/null
sleep 6
S $R1 "ping -c 2 -W 2 10.60.60.2 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | sed 's/^/  R1 -> R2 underlay: /'

echo; echo "===== 2. VXLAN tunnels, VNI 100 ====="
# VXLAN carries Ethernet frames, so the tunnel belongs in a bridge, not on an
# L3 address. The first attempt put 10.61.61.x straight on tun0; the tunnel came
# up in both the kernel and the dataplane and transmitted nothing, because that
# is not the mode it exists for. The address goes on the bridge.
cli $R1 "set interfaces tunnel tun0 encapsulation vxlan" \
        "set interfaces tunnel tun0 vxlan-id 100" \
        "set interfaces tunnel tun0 local-ip 10.60.60.1" \
        "set interfaces tunnel tun0 remote-ip 10.60.60.2" \
        "set interfaces bridge br0" \
        "set interfaces bridge br0 address 10.61.61.1/24" \
        "set interfaces tunnel tun0 bridge-group bridge br0" | sed 's/^/  R1: /'
cli $R2 "set interfaces tunnel tun0 encapsulation vxlan" \
        "set interfaces tunnel tun0 vxlan-id 100" \
        "set interfaces tunnel tun0 local-ip 10.60.60.2" \
        "set interfaces tunnel tun0 remote-ip 10.60.60.1" \
        "set interfaces bridge br0" \
        "set interfaces bridge br0 address 10.61.61.2/24" \
        "set interfaces tunnel tun0 bridge-group bridge br0" | sed 's/^/  R2: /'
sleep 10

echo; echo "===== 3. Did the dataplane create it? ====="
S $R1 'printf "  kernel tun0: %s\n" "$(ip -d link show tun0 2>/dev/null | grep -oE "vxlan id [0-9]+.*" | head -1 || echo absent)"
       echo "  dataplane:"
       sudo /opt/vyatta/bin/vplsh -l -c ifconfig 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
for i in d.get(\"interfaces\", []):
    if i.get(\"name\") == \"tun0\":
        print(\"    type=%s vxlan=%s\" % (i.get(\"type\"), i.get(\"vxlan\")))
" 2>/dev/null' | tail -4

echo; echo "===== 4. Does it forward? ====="
# Establish that the tunnel exists before believing anything about forwarding.
# Without this the first run reported "VXLAN does not forward" when in fact
# every set had been rejected for a bad interface name and there was no tunnel
# at all -- a config error dressed up as a dataplane finding.
exists=$(S $R1 'ip link show tun0 >/dev/null 2>&1 && echo yes || echo no' | tail -1 | tr -dc 'a-z')
printf '  tunnel exists: %s\n' "$exists"
got=$(S $R1 "ping -c 4 -W 2 10.61.61.2 2>&1 | grep -oE '[0-9]+ received'" | tail -1)
printf '  ping R1 -> R2 over VXLAN: %s of 4\n' "$got"
S $R1 'printf "  tun0 dataplane counters: %s\n" "$(sudo /opt/vyatta/bin/vplsh -l -c "ifconfig tun0" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
for i in d.get(\"interfaces\", []):
    s = i.get(\"statistics\", {})
    print(\"tx=%s rx=%s txerr=%s\" % (s.get(\"tx_packets\"), s.get(\"rx_packets\"), s.get(\"tx_errors\")))
" 2>/dev/null)"' | tail -1

echo; echo "===== 5. Does bgpd do EVPN here? ====="
S $R1 'printf "  bgpd running: %s (shipped daemons already enables it)\n" "$(pgrep -xc bgpd)"
       echo "  address-family l2vpn evpn accepted:"
       sudo vtysh -c "configure terminal" -c "router bgp 65001" -c "address-family l2vpn evpn" -c "advertise-all-vni" -c "end" 2>&1 | tail -3 | sed "s/^/    /"
       echo "  running-config:"
       sudo vtysh -c "show running-config" 2>&1 | grep -A4 "l2vpn evpn" | head -6 | sed "s/^/    /"' | tail -12

echo; echo "===== 6. Does zebra see a VNI? ====="
S $R1 'echo "  show evpn vni:"; sudo vtysh -c "show evpn vni" 2>&1 | head -6 | sed "s/^/    /"
       echo "  show evpn mac vni all:"; sudo vtysh -c "show evpn mac vni all" 2>&1 | head -4 | sed "s/^/    /"' | tail -12

echo; echo "===== 7. Verdict ====="
n=$(printf '%s' "$got" | tr -dc '0-9')
if [ "${exists:-no}" != "yes" ]; then
	echo "  INCONCLUSIVE: the tunnel was never created, so this says nothing"
	echo "  about VXLAN. Read section 2 for the configuration errors."
elif [ -n "$n" ] && [ "$n" -ge 3 ]; then
	echo "  VXLAN forwards. The transport EVPN would need is present and working."
	echo "  Whether EVPN itself is reachable depends on sections 5 and 6 above:"
	echo "  bgpd accepting the address family is necessary and not sufficient --"
	echo "  what matters is whether zebra learns a VNI from the VXLAN interface,"
	echo "  because that is what drives the FDB programming the dataplane already"
	echo "  handles in vxlan_neigh_change()."
else
	echo "  VXLAN does NOT forward. EVPN is moot until that is fixed, and VPLS"
	echo "  is the better use of the next block of work."
fi

echo; echo "===== 8. Clean up ====="
S $R1 'sudo vtysh -c "configure terminal" -c "no router bgp 65001" -c "end" >/dev/null 2>&1' > /dev/null
cli $R1 "delete interfaces tunnel tun0" "delete interfaces bridge br0" \
        "delete interfaces dataplane dp0s9 address 10.60.60.1/24" > /dev/null
cli $R2 "delete interfaces tunnel tun0" "delete interfaces bridge br0" \
        "delete interfaces dataplane dp0s3 address 10.60.60.2/24" > /dev/null
sleep 6
for h in $R1 $R2; do
	S "$h" 'printf "  %s tun0 gone: %s\n" "$(hostname)" "$(ip link show tun0 >/dev/null 2>&1 && echo no || echo yes)"' | tail -1
done
