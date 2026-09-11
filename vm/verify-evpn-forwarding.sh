#!/bin/bash
# Does a MAC programmed by EVPN forward, or only a MAC the data path learned?
#
# The first version of this test asked the wrong question. It killed R1's flood
# path -- tunnel remote-ip 10.60.60.99, which nothing answers -- and took a
# ping that only worked after EVPN came up as proof that the EVPN entry carried
# it. It did not. R1 and R2 are bridged, so every frame R2 floods toward R1
# teaches R1 the source MAC with the source VTEP attached, and R1 had learned
# R3's MAC from the data path before EVPN was configured at all:
#
#   "mac": "52:54:0:3:8:1", "remote_ip": "10.60.60.2", "type": "dynamic"
#
# Blocking the flood path out of R1 does nothing about learning into R1. The
# two candidate entries have to be told apart by what they are, not by where
# the traffic can go, and the table says which is which:
#
#   type "dynamic"      the data path learned it
#   type "permanent"    netlink programmed it, which is how EVPN arrives
#
# So: clear R1's table, make FRR reprogram it, confirm nothing but the
# permanent entry is present, and only then send traffic. If the first frame
# reaches R3, the permanent entry carried it -- there was nothing else. The
# drop counter says the same thing from the other side: vxlan_output() takes
# "goto drop" and bumps OutDiscards for an entry it cannot use.
#
# Needs the image with the vxlan_newneigh() IFBAF_ADDR_V4 fix. Older dumps emit
# "IPAddr" instead of "remote_ip" and the script stops if it sees one, because
# on that image every reading below is about a different defect.
#
#   R1  VTEP 10.60.60.1, br0 = tun0 only,     tunnel remote-ip 10.60.60.99
#   R2  VTEP 10.60.60.2, br0 = tun0 + dp0s8,  tunnel remote-ip 10.60.60.1
#   R3  host on dp0s8 10.61.61.3/24
#
# TOPO=ipsec wiring: R1.dp0s9 <-> R2.dp0s3, R2.dp0s8 <-> R3.dp0s8.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-evpn-forwarding.log}
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

macs_json() { S $R1 "sudo /opt/vyatta/bin/vplsh -l -c 'vxlan macs show' 2>/dev/null"; }

# Report the entry for R3's MAC as "<type> <remote_ip> <forwards>", or "absent".
entry_for_mac() {
	macs_json | python3 -c "
import sys, json
want = '$MAC3'
try:
    d = json.load(sys.stdin)
except Exception:
    print('unreadable'); sys.exit()
for t in d.get('mac_table', []):
    for e in t.get('entries', []):
        if 'IPAddr' in e:
            print('old-image'); sys.exit()
        if e.get('mac') == want:
            print('%s %s %s' % (e.get('type'), e.get('remote_ip') or '-',
                                e.get('forwards')))
            sys.exit()
print('absent')
" 2>/dev/null | tail -1
}

outdiscards() {
	S $R1 "sudo /opt/vyatta/bin/vplsh -l -c 'vxlan stats show' 2>/dev/null \
	       | python3 -c 'import sys,json; print(json.load(sys.stdin).get(\"OutDiscards\",\"?\"))' 2>/dev/null" \
	  | tail -1 | tr -dc '0-9?'
}

# Unicast from the first frame: a static neighbour, so no ARP and therefore no
# broadcast. An ARP would take the flood path and fail for the wrong reason.
ping_r3() {
	S $R1 "sudo ip neigh replace 10.61.61.3 lladdr $MAC3 dev br0 2>/dev/null
	       ping -c 3 -W 2 10.61.61.3 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | tr -dc '0-9'
}

cleanup() {
	echo; echo "===== Clean up ====="
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
}

echo "===== 1. Topology ====="
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

if [ "$(entry_for_mac)" = "old-image" ]; then
	echo
	echo "  STOP: this dataplane still prints IPAddr, so it predates the"
	echo "  vxlan_newneigh() fix. On that image an EVPN entry carries no"
	echo "  address flag and vxlan_output() drops it, which is the thing"
	echo "  this test is meant to measure. Install the new image first."
	cleanup
	exit 2
fi

# R2 has to have learned R3's MAC locally or there is nothing to advertise.
S $R2 "ping -c 3 -W 2 10.61.61.3 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | sed 's/^/  R2 -> R3 (so R2 learns it): /'
sleep 4
echo "  R1 already holds: $(entry_for_mac)"
echo "  (dynamic here is expected and is exactly why the old test was wrong)"

echo; echo "===== 2. Bring up EVPN ====="
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

echo; echo "===== 3. Leave only the EVPN entry ====="
# Clearing takes the netlink entry with the learned one, so make FRR resend it.
S $R1 "sudo /opt/vyatta/bin/vplsh -l -c 'vxlan macs clear tun0' >/dev/null 2>&1" > /dev/null
echo "  table cleared, R1 holds: $(entry_for_mac)"
S $R1 'sudo vtysh -c "clear bgp l2vpn evpn *" >/dev/null 2>&1' > /dev/null
sleep 50
entry=$(entry_for_mac)
echo "  after BGP reprogrammed it, R1 holds: $entry"
etype=${entry%% *}

echo; echo "===== 4. Send traffic with nothing else in the table ====="
before=$(outdiscards)
got=$(ping_r3)
after=$(outdiscards)
echo "  OutDiscards: ${before:-?} -> ${after:-?}"
echo "  R1 -> R3: ${got:-?} of 3"
echo "  R1 holds afterwards: $(entry_for_mac)"
echo "  (dynamic afterwards is fine -- R3's replies arrive over the tunnel"
echo "   and the data path relearns it. What matters is step 3.)"

echo; echo "===== 5. Verdict ====="
if [ "$entry" = "absent" ] || [ "$entry" = "unreadable" ]; then
	echo "  INCONCLUSIVE: after the clear and the BGP refresh there was no"
	echo "  entry for $MAC3 at all, so the ping measured nothing. FRR did"
	echo "  not reprogram it; check that the session came back up."
elif [ "$etype" != "permanent" ]; then
	echo "  INCONCLUSIVE: the entry is \"$entry\", not permanent, so the data"
	echo "  path relearned it before the traffic went out and this is the"
	echo "  same confusion the first version of this test fell into."
elif [ "${got:-0}" -ge 2 ]; then
	echo "  THE EVPN ENTRY FORWARDS. The only entry for $MAC3 when the"
	echo "  traffic went out was the one netlink programmed, and it reached"
	echo "  R3 with the flood path pointed at 10.60.60.99."
	[ "$before" = "$after" ] && echo "  OutDiscards did not move, which says the same from the other side."
else
	echo "  THE EVPN ENTRY DOES NOT FORWARD. It is present, it names the"
	echo "  right VTEP, and traffic to it does not reach R3."
	[ "$before" != "$after" ] && \
	  echo "  OutDiscards moved ${before:-?} -> ${after:-?}: vxlan_output() is dropping."
fi

cleanup
