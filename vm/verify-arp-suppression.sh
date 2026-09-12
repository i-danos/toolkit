#!/bin/bash
# Does ARP suppression actually stop the flood?
#
# Reachability cannot answer this. ARP resolves whether the bridge answers
# locally or floods the request to every leaf, so a ping proves nothing either
# way -- the same trap as the first EVPN forwarding test, which measured a
# path that worked for a reason it had not excluded.
#
# What separates the two is where the request goes, and the dataplane counts
# it: "bridge <name> arp-suppression" reports how many requests were answered
# from the neighbour table and how many still flooded.
#
# The ARP has to come from a host in the bridge domain, not from the router.
# The first version of this test drove it from R1's own L3 stack and measured
# nothing at all -- both counters stayed zero with suppression on -- because a
# leaf with an SVI never ARPs for a remote host in the first place: zebra has
# already installed the neighbour from the EVPN route, and deleting it locally
# just makes zebra put it back. That is the feature working one layer down,
# and it is also why suppression exists for the hosts rather than the router:
# a host attached to the bridge has no BGP session and will flood.
#
# So the request comes from R3, through R2, which is the leaf the host is
# attached to and the one configured to suppress.
#
# The counters cannot measure the "off" case: the fast path returns before
# them when suppression is disabled, deliberately, so a feature nobody enabled
# costs nothing. The flood itself is measured instead, on R2's tunnel out of
# the bridge domain -- which is the thing the feature exists to prevent and
# reads the same in both states.
#
#   R1  VTEP 10.60.60.1   br10 10.10.10.1/24 (tun10), br20 10.20.20.1/24 (tun20), both RED
#   R2  VTEP 10.60.60.2   br10 10.10.10.2/24 (tun10), br20 10.20.20.2/24 (tun20 + dp0s8)
#   R3  host 10.20.20.3/24 on dp0s8
#
# R2 needs the br20 address. Only a leaf with an SVI in the host's subnet
# learns the host's IP-to-MAC binding; a pure L2 leaf sees the MAC alone and
# advertises a MAC-only type-2 route, leaving nothing for suppression to
# answer from. That is not a detail of this test -- it is the deployment rule
# the feature depends on, and the flooded counter is what reveals it when an
# operator gets it wrong.
#
# TOPO=ipsec wiring: R1.dp0s9 <-> R2.dp0s3, R2.dp0s8 <-> R3.dp0s8.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-arp-suppression.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.155
R2=192.168.203.156
R3=192.168.203.157
# What R3 asks about: an address that lives on the far side of the tunnel.
TARGET=10.20.20.1
pass=0
fail=0

exec > "$OUT" 2>&1
S() { docker exec danos-robot timeout 200 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$1" "$2" 2>&1; }

cli() {
	local h=$1; shift
	local c=""
	for x in "$@"; do c="$c vcli -s \$SID -c \"$x\" 2>&1;"; done
	S "$h" "SID=\$\$; eval \"\$(cli-shell-api getSessionEnv \$SID)\"; cli-shell-api setupSession; $c
	        vcli -s \$SID -c commit 2>&1 | grep -viE 'sssd|configuration db|grub|boot-loader|crash dump|^\s*\$'"
}

ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; shift; printf '%s\n' "$@" | head -6 | sed 's/^/        /'; fail=$((fail + 1)); }

# Returns "enabled suppressed flooded", or "unreadable". Read as three fields
# so a failure to parse cannot be mistaken for a counter that did not move --
# that mistake has been made twice in this toolkit already.
supp_state() {
	S $R2 "sudo /opt/vyatta/bin/vplsh -l -c 'bridge br20 arp-suppression' 2>/dev/null \
	       | python3 -c 'import sys,json
d=json.load(sys.stdin)[\"arp_suppression\"]
print(d[\"enabled\"], d[\"suppressed\"], d[\"flooded\"])' 2>/dev/null" | tail -1 | grep -E '^(True|False) [0-9]+ [0-9]+$' || echo unreadable
}

# Packets R2 encapsulated into the fabric. A flooded ARP is one of them; a
# suppressed one is not.
#
# Not the tunnel interface's tx_packets. That field exists in the JSON and is
# never incremented: a VXLAN interface transmits by building the outer packet
# and handing it to the underlay port, so the physical port's counters move
# and the tunnel's do not. Reading it gave "0 -> 0" across an ARP that
# demonstrably crossed the tunnel -- R3 resolved the address -- which is a
# counter that exists, parses, and means nothing. VXLAN_STATS_OUTPKTS is
# incremented on the send path itself.
vxlan_out() {
	S $R2 "sudo /opt/vyatta/bin/vplsh -l -c 'vxlan stats show' 2>/dev/null \
	       | python3 -c 'import sys,json
print(json.load(sys.stdin)[\"vxlan_stats\"][\"OutPkts\"])' 2>/dev/null" | tail -1 | grep -E '^[0-9]+$' || echo ""
}

# One ARP from a real host in the bridge domain, asking about an address that
# only exists across the tunnel. R3 has no BGP session, so it must ask -- which
# is the case suppression is for. The router itself never would: zebra has
# already given it the answer.
one_arp() {
	S $R3 "sudo ip -4 neigh del $TARGET dev dp0s8 2>/dev/null
	       ping -c 1 -W 3 $TARGET >/dev/null 2>&1
	       echo done" > /dev/null
	sleep 3
}

cleanup() {
	echo; echo "===== Clean up ====="
	cli $R2 "delete interfaces bridge br20 arp-suppression" > /dev/null 2>&1
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

echo "===== 1. IRB fabric with EVPN, both leaves holding an SVI ====="
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
# Give both leaves something to advertise, and give R2 a reason to have
# learned the far SVI.
S $R2 "ping -c 3 -W 2 10.20.20.3 >/dev/null 2>&1"
S $R1 "sudo ip vrf exec vrfRED ping -c 3 -W 2 -I 10.20.20.1 10.20.20.2 >/dev/null 2>&1"
sleep 25

echo
echo "===== 2. R2 can answer for $TARGET without asking the fabric ====="
# The precondition is about R2 and about the address R3 will ask for. R2 is
# the leaf that will suppress; if its neighbour table has no entry for the
# target then suppression has nothing to answer from and will correctly fall
# through to flooding, which would fail step 5 for a reason that is not a
# defect.
ev=$(S $R2 "sudo /opt/vyatta/bin/vplsh -l -c 'arp show' 2>/dev/null")
printf '%s' "$ev" | tr ',' '\n' | grep -A1 "$TARGET" | head -4 | sed 's/^/    /'
if printf '%s' "$ev" | grep -q "\"ip\":\"$TARGET\""; then
	ok "R2's neighbour table holds $TARGET, so there is something to answer from"
else
	bad "R2's neighbour table holds $TARGET, so there is something to answer from" \
	    "no entry for $TARGET in R2's arp table"
fi
echo "  R2's EVPN view of VNI 20:"
S $R2 'sudo vtysh -c "show evpn arp-cache vni 20" 2>&1 | tail -3' | sed 's/^/    /' 

echo
echo "===== 3. Suppression off: the request floods out of the fabric ====="
st=$(supp_state)
echo "    state: $st"
if [ "$st" = "unreadable" ]; then
	bad "the dataplane reports its suppression state" "vplsh returned nothing parseable"
	cleanup; exit 1
fi
set -- $st
[ "$1" = "False" ] && ok "suppression starts off" || bad "suppression starts off" "enabled=$1"

# Counters cannot be used here: with suppression off the fast path returns
# before them. The flood is measured on the tunnel instead.
tx_before=$(vxlan_out)
one_arp
tx_after=$(vxlan_out)
echo "    R2 VXLAN OutPkts: ${tx_before:-unreadable} -> ${tx_after:-unreadable}"
echo "    R3's ARP cache, which is what the request resolved into:"
S $R3 "ip -4 neigh show dev dp0s8 | grep '$TARGET'" | sed 's/^/      /' | tail -1
if [ -z "$tx_before" ] || [ -z "$tx_after" ]; then
	bad "the tunnel counter is readable" "one of the samples did not parse"
elif [ "$tx_after" -gt "$tx_before" ]; then
	ok "with it off the ARP was encapsulated into the fabric ($tx_before -> $tx_after)"
else
	bad "with it off the ARP was encapsulated into the fabric" "OutPkts stayed at $tx_after"
fi
off_delta=$(( ${tx_after:-0} - ${tx_before:-0} ))

echo
echo "===== 4. Turn it on ====="
out=$(cli $R2 "set interfaces bridge br20 arp-suppression")
if [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then printf '%s\n' "$out" | sed 's/^/    /'; fi
sleep 8
st=$(supp_state); set -- $st
echo "    state: $st"
[ "$1" = "True" ] && ok "the dataplane took the configuration" || bad "the dataplane took the configuration" "enabled=$1"
before_s=$2
before_f=$3

echo
echo "===== 5. Suppression on: the request is answered, not flooded ====="
tx_before=$(vxlan_out)
one_arp
tx_after=$(vxlan_out)
st=$(supp_state); set -- $st
echo "    state after one ARP: $st"
echo "    R2 VXLAN OutPkts: ${tx_before:-unreadable} -> ${tx_after:-unreadable}"
if [ "$2" -gt "$before_s" ]; then
	ok "the request was answered from the neighbour table ($before_s -> $2)"
else
	bad "the request was answered from the neighbour table" "suppressed stayed at $2"
fi
if [ "$3" -eq "$before_f" ]; then
	ok "the flooded counter did not move ($before_f unchanged)"
else
	bad "the flooded counter did not move" "flooded moved $before_f -> $3"
fi
# The counters say what the bridge decided; this says what left the box.
on_delta=$(( ${tx_after:-0} - ${tx_before:-0} ))
if [ "$on_delta" -lt "$off_delta" ]; then
	ok "and less was encapsulated than with it off ($off_delta -> $on_delta)"
else
	bad "and less went over the tunnel than with it off" \
	    "off sent $off_delta, on sent $on_delta"
fi

echo
echo "===== 6. The host is still reachable ====="
# Suppression that answers with the wrong MAC would show the same counters and
# break forwarding, so the counters alone are not enough.
got=$(S $R3 "sudo ip -4 neigh del $TARGET dev dp0s8 2>/dev/null
             ping -c 3 -W 3 $TARGET 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | tr -dc '0-9')
if [ "${got:-0}" -ge 2 ]; then
	ok "R3 still reaches $TARGET: $got of 3"
else
	bad "R3 still reaches $TARGET" "got $got of 3 -- the answer may carry the wrong MAC"
fi

echo
echo "===== 7. An unknown address still floods ====="
# The fallback matters: a host EVPN has not advertised yet must still be
# reachable, at the cost of one broadcast.
before_f=$(supp_state | cut -d' ' -f3)
S $R3 "ping -c 1 -W 2 10.20.20.77 >/dev/null 2>&1" > /dev/null
sleep 3
after_f=$(supp_state | cut -d' ' -f3)
if [ "${after_f:-0}" -gt "${before_f:-0}" ]; then
	ok "an address the table does not hold is still flooded ($before_f -> $after_f)"
else
	bad "an address the table does not hold is still flooded" "flooded stayed at $after_f"
fi

echo
echo "===== 8. Result ====="
printf '  %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
	echo "  ARP SUPPRESSION WORKS. The same request floods with it off and is"
	echo "  answered with it on, the host stays reachable, and an address the"
	echo "  neighbour table does not hold still floods."
else
	echo "  Something above did not hold. If step 5 shows the flooded counter"
	echo "  rising instead of suppressed, the neighbour table had no entry:"
	echo "  check step 2, and check that R2 has an address in 10.20.20.0/24 --"
	echo "  a leaf with no SVI in the subnet never learns the host's IP and so"
	echo "  advertises a MAC-only route with nothing to suppress from."
fi

cleanup
exit "$fail"
