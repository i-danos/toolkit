#!/bin/bash
# EVPN-VXLAN end to end: does a MAC learned on one router reach the other's
# forwarding table?
#
# Four of the five pieces were established already (L2VPN-EVPN-OVER-VPLS.md):
# VXLAN forwards in bridge mode, zebra finds the VNI on a DANOS interface on its
# own, bgpd brings up an EVPN session, and a remote MAC written to the kernel
# FDB reaches the dataplane. The fifth did not exist -- learning stopped in the
# dataplane and never reached the kernel, so zebra had nothing to advertise and
# "show evpn vni" reported 0 MACs while the bridge table held several.
#
# The bridge now reports learned MACs to the kernel FDB from its ageing timer.
# This walks the whole chain with that in place:
#
#   R2 learns R3's MAC on dp0s8  ->  R2 kernel FDB  ->  R2 zebra
#     ->  BGP type-2  ->  R1 zebra  ->  R1 kernel FDB
#     ->  vxlan_neigh_change()  ->  R1 dataplane
#
# Each hop is checked separately, because a break at any of them produces the
# same end symptom -- no remote MAC -- and the previous round showed how easily
# that gets attributed to the wrong hop.
#
#   R1  VTEP 10.60.60.1, br0 = tun0,          br0 10.61.61.1/24
#   R2  VTEP 10.60.60.2, br0 = tun0 + dp0s8,  br0 10.61.61.2/24
#   R3  host on dp0s8 10.61.61.3/24
#   R1 and R2 both in AS 65000.
#
# R2 needs a local bridge port with something behind it, and R3 is it. Without
# one there is nothing local to advertise: the first run bridged only the
# tunnel at both ends, so every MAC either belonged to the bridge interface
# itself or had been learned over the tunnel, and "0 MACs" was the correct
# answer to a question worth nothing.
#
# iBGP, deliberately. With eBGP, FRR's bgp ebgp-requires-policy default filters
# every prefix and "show bgp l2vpn evpn summary" reports (Policy) in place of a
# count -- the session comes up and carries nothing, which reads exactly like a
# broken advertisement path. That cost a round last time.
#
# TOPO=ipsec wiring: R1.dp0s9 <-> R2.dp0s3.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-evpn-e2e.log}
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

vtep() {   # host underlay-if local remote braddr [local-bridge-port]
	cli "$1" "set interfaces dataplane $2 address $3/24" \
	         "set interfaces tunnel tun0 encapsulation vxlan" \
	         "set interfaces tunnel tun0 vxlan-id 100" \
	         "set interfaces tunnel tun0 local-ip $3" \
	         "set interfaces tunnel tun0 remote-ip $4" \
	         "set interfaces bridge br0" \
	         "set interfaces bridge br0 address $5/24" \
	         "set interfaces tunnel tun0 bridge-group bridge br0" > /dev/null
	[ -n "${6:-}" ] && \
		cli "$1" "set interfaces dataplane $6 bridge-group bridge br0" > /dev/null
	return 0
}

echo "===== 1. Two VTEPs on VNI 100, R2 with a local port ====="
vtep $R1 dp0s9 10.60.60.1 10.60.60.2 10.61.61.1
vtep $R2 dp0s3 10.60.60.2 10.60.60.1 10.61.61.2 dp0s8
cli $R3 "set interfaces dataplane dp0s8 address 10.61.61.3/24" > /dev/null
sleep 12
S $R1 "ping -c 2 -W 2 10.61.61.2 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | sed 's/^/  overlay R1 -> R2: /'
MAC3=$(S $R3 "cat /sys/class/net/dp0s8/address" | tail -1)
echo "  R3 dp0s8 MAC: $MAC3   <- the MAC that has to travel"
# Traffic from R3 so R2 learns that MAC on a local port. Nothing is advertised
# until something is learned.
S $R2 "ping -c 3 -W 2 10.61.61.3 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | sed 's/^/  R2 -> R3 (to learn): /'
sleep 4

echo; echo "===== 2. iBGP EVPN, both in AS 65000 ====="
S $R1 'sudo vtysh -c "configure terminal" -c "router bgp 65000" \
  -c "neighbor 10.60.60.2 remote-as 65000" -c "neighbor 10.60.60.2 update-source 10.60.60.1" \
  -c "address-family l2vpn evpn" -c "neighbor 10.60.60.2 activate" -c "advertise-all-vni" \
  -c "end" >/dev/null 2>&1; echo "  R1 configured"' | tail -1
S $R2 'sudo vtysh -c "configure terminal" -c "router bgp 65000" \
  -c "neighbor 10.60.60.1 remote-as 65000" -c "neighbor 10.60.60.1 update-source 10.60.60.2" \
  -c "address-family l2vpn evpn" -c "neighbor 10.60.60.1 activate" -c "advertise-all-vni" \
  -c "end" >/dev/null 2>&1; echo "  R2 configured"' | tail -1
sleep 40

echo; echo "===== 3. Hop by hop ====="

echo "  -- R2: does the dataplane know R3's MAC on a local port? --"
S $R2 'sudo /opt/vyatta/bin/vplsh -l -c "bridge br0 macs show" 2>&1 \
       | grep -oE "\"mac\":\"[^\"]*\",\"port\":\"[^\"]*\"" | head -5 | sed "s/^/    /"' | tail -5

echo "  -- R2: did it reach the kernel FDB? --"
S $R2 '/sbin/bridge fdb show br br0 2>/dev/null | grep -v permanent | head -4 | sed "s/^/    /"
       printf "    dynamic entries: %s\n" "$(/sbin/bridge fdb show br br0 2>/dev/null | grep -vc permanent)"' | tail -5

echo "  -- R2: did zebra pick it up? --"
S $R2 'sudo vtysh -c "show evpn vni" 2>&1 | tail -2 | sed "s/^/    /"
       sudo vtysh -c "show evpn mac vni 100" 2>&1 | tail -6 | sed "s/^/    /"' | tail -8

echo "  -- BGP: is it advertised? --"
S $R2 'sudo vtysh -c "show bgp l2vpn evpn summary" 2>&1 | grep -E "10.60.60.1" | sed "s/^/    /"
       sudo vtysh -c "show bgp l2vpn evpn" 2>&1 | tail -8 | sed "s/^/    /"' | tail -10

echo "  -- R1: did zebra receive it? --"
S $R1 'sudo vtysh -c "show evpn mac vni 100" 2>&1 | tail -6 | sed "s/^/    /"' | tail -6

echo "  -- R1: did it reach the kernel FDB with a remote VTEP? --"
S $R1 '/sbin/bridge fdb show dev tun0 2>/dev/null | grep "dst " | head -4 | sed "s/^/    /"
       printf "    remote entries: %s\n" "$(/sbin/bridge fdb show dev tun0 2>/dev/null | grep -c "dst ")"' | tail -5

echo "  -- R1: did it reach the DATAPLANE? --"
S $R1 'sudo /opt/vyatta/bin/vplsh -l -c "vxlan macs show" 2>&1 \
       | grep -oE "\"mac\":\"[^\"]*\"" | head -4 | sed "s/^/    /"' | tail -4

echo; echo "===== 4. Verdict ====="
k1=$(S $R2 "/sbin/bridge fdb show br br0 2>/dev/null | grep -v permanent | grep -c dp0s8" | tail -1 | tr -dc '0-9')
z1=$(S $R2 'sudo vtysh -c "show evpn vni" 2>&1 | awk "/^100/{print \$4}"' | tail -1 | tr -dc '0-9')
k2=$(S $R1 '/sbin/bridge fdb show dev tun0 2>/dev/null | grep -c "dst "' | tail -1 | tr -dc '0-9')
d2=$(S $R1 'sudo /opt/vyatta/bin/vplsh -l -c "vxlan macs show" 2>&1 | grep -cE "\"mac\""' | tail -1 | tr -dc '0-9')
printf '  R2 kernel FDB on dp0s8=%s   R2 zebra MACs=%s   R1 kernel remote=%s   R1 dataplane=%s\n' \
	"${k1:-?}" "${z1:-?}" "${k2:-?}" "${d2:-?}"

if [ "${k1:-0}" -eq 0 ]; then
	echo "  STOPS AT HOP 1: R2 is not reporting the MAC it learned on dp0s8 to"
	echo "  the kernel. That is the mechanism this change adds; check the bridge"
	echo "  has a VXLAN member, which is the condition for reporting, and that"
	echo "  R2 learned R3's MAC at all."
elif [ "${z1:-0}" -eq 0 ]; then
	echo "  STOPS AT HOP 2: R2's kernel has the MAC and its zebra has not taken"
	echo "  it."
elif [ "${k2:-0}" -eq 0 ]; then
	echo "  STOPS AT HOP 3: R2's zebra has it and R1 never received it. Check"
	echo "  the BGP session and the advertisement in section 3."
elif [ "${d2:-0}" -eq 0 ]; then
	echo "  STOPS AT HOP 4: R1's kernel has it and its dataplane does not, which"
	echo "  is vxlan_neigh_change() -- previously measured as working."
else
	echo "  END TO END: a MAC learned on R2's local port is in R1's forwarding"
	echo "  table. EVPN-VXLAN carries traffic on this image."
fi

echo; echo "===== 5. Clean up ====="
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
