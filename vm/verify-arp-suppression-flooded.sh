#!/bin/bash
# What exactly does the flooded counter count?
#
# verify-arp-suppression.sh already showed it rises when the neighbour table
# has no answer. That is one assertion, "greater than", against a ping -- and a
# ping is not one ARP request: the kernel's neighbour state machine sends up to
# three solicitations, backs off, then caches the failure, so the number of
# requests reaching the bridge is somewhere between one and three and differs
# on the second attempt. "Greater than" against an unknown number of requests
# cannot distinguish a counter that counts once per request from one that
# counts twice, or one that also counts things it should not.
#
# So this drives exact numbers of exact frames with send-arp.py and asserts
# exact deltas. What it pins down:
#
#   off        the counter is frozen, by design -- the fast path returns before
#              it, so a feature nobody enabled costs nothing. The flood itself
#              still happens, and is measured separately so that "frozen" is
#              not confused with "nothing was sent".
#   quiet      nothing else in the fabric moves the counters, which is what
#              makes the exact deltas below meaningful rather than lucky.
#   one each   N unanswerable requests raise flooded by exactly N.
#   disjoint   an answerable request raises suppressed and never flooded;
#              a mixed burst splits with no cross-talk.
#   gated      ARP replies and non-ARP broadcasts take the same flood path and
#              move neither counter.
#   temporary  a rising flooded is a diagnosis, not a steady state: the same
#              address stops flooding the moment the table can answer for it.
#
# That last one is the operational meaning of the counter and the reason it is
# worth having. flooded climbing on a leaf that should be suppressing is how an
# operator finds out the leaf has no SVI in the host's subnet, or that the
# fabric never advertised the host -- and it is the same reading in both cases,
# which is why the test ends by showing the counter go quiet once the binding
# arrives rather than only showing it rise.
#
#   R1  VTEP 10.60.60.1   br10 10.10.10.1/24 (tun10), br20 10.20.20.1/24 (tun20), both RED
#   R2  VTEP 10.60.60.2   br10 10.10.10.2/24 (tun10), br20 10.20.20.2/24 (tun20 + dp0s8)
#   R3  host 10.20.20.3/24 on dp0s8, the only thing here that has to ARP
#
# TOPO=ipsec wiring: R1.dp0s9 <-> R2.dp0s3, R2.dp0s8 <-> R3.dp0s8.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-/home/aikon/danos/.obs/verify-arp-suppression-flooded.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.155
R2=192.168.203.156
R3=192.168.203.157
# An address the fabric holds, so the table can answer for it.
HIT=10.20.20.1
# An address nothing holds -- until step 10 gives it to R1.
MISS=10.20.20.77
SENDER=10.20.20.3
IF=dp0s8
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

# "enabled suppressed flooded", or "unreadable". Three fields, read as three
# fields: a parse failure that silently becomes "0" reads exactly like a
# counter that did not move, and that mistake has been made twice already in
# this toolkit.
supp_state() {
	S $R2 "sudo /opt/vyatta/bin/vplsh -l -c 'bridge br20 arp-suppression' 2>/dev/null \
	       | python3 -c 'import sys,json
d=json.load(sys.stdin)[\"arp_suppression\"]
print(d[\"enabled\"], d[\"suppressed\"], d[\"flooded\"])' 2>/dev/null" | tail -1 | grep -E '^(True|False) [0-9]+ [0-9]+$' || echo unreadable
}

# Packets R2 encapsulated into the fabric. Not the tunnel interface's
# tx_packets: that field exists in the JSON and is never incremented, because a
# VXLAN interface transmits by building the outer packet and handing it to the
# underlay port. Reading it gave "0 -> 0" across an ARP that demonstrably
# crossed the tunnel.
vxlan_out() {
	S $R2 "sudo /opt/vyatta/bin/vplsh -l -c 'vxlan stats show' 2>/dev/null \
	       | python3 -c 'import sys,json
print(json.load(sys.stdin)[\"vxlan_stats\"][\"OutPkts\"])' 2>/dev/null" | tail -1 | grep -E '^[0-9]+$' || echo ""
}

# send <count> <kind> <target>
send() {
	S $R3 "sudo python3 /tmp/send-arp.py $IF $SENDER $3 $1 $2" | grep -oE 'sent [0-9]+ [a-z]+' | tail -1
	sleep 3
}

# measure <count> <kind> <target> -> sets d_supp, d_flood, d_out
d_supp=0; d_flood=0; d_out=0
measure() {
	local before after o_before o_after
	before=$(supp_state)
	o_before=$(vxlan_out)
	[ "$before" = unreadable ] && { d_supp=-1; d_flood=-1; d_out=-1; return; }
	local sent
	sent=$(send "$1" "$2" "$3")
	after=$(supp_state)
	o_after=$(vxlan_out)
	[ "$after" = unreadable ] && { d_supp=-1; d_flood=-1; d_out=-1; return; }
	set -- $before; local bs=$2 bf=$3
	set -- $after;  local as=$2 af=$3
	d_supp=$((as - bs))
	d_flood=$((af - bf))
	d_out=$(( ${o_after:-0} - ${o_before:-0} ))
	printf '    %-22s suppressed %s -> %s (%+d)   flooded %s -> %s (%+d)   OutPkts %+d\n' \
	       "$sent" "$bs" "$as" "$d_supp" "$bf" "$af" "$d_flood" "$d_out"
}

# exact <name> <expected-suppressed> <expected-flooded>
exact() {
	if [ "$d_supp" -eq "$2" ] && [ "$d_flood" -eq "$3" ]; then
		ok "$1"
	else
		bad "$1" "expected suppressed +$2 flooded +$3, got suppressed +$d_supp flooded +$d_flood"
	fi
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
	S $R3 "sudo rm -f /tmp/send-arp.py" > /dev/null
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
# Give R2 a reason to have learned the far SVI.
S $R2 "ping -c 3 -W 2 10.20.20.3 >/dev/null 2>&1"
S $R1 "sudo ip vrf exec vrfRED ping -c 3 -W 2 -I $HIT 10.20.20.2 >/dev/null 2>&1"
sleep 25

b64=$(base64 -w0 "$HERE/send-arp.py")
S $R3 "echo '$b64' | base64 -d | sudo tee /tmp/send-arp.py >/dev/null; sudo chmod 755 /tmp/send-arp.py"
out=$(S $R3 "sudo python3 /tmp/send-arp.py $IF $SENDER $HIT 1 request")
echo "    sender installed: $out"
if printf '%s' "$out" | grep -q 'sent 1 request'; then
	ok "R3 can put an exact number of frames on the wire"
else
	bad "R3 can put an exact number of frames on the wire" "$out"
	cleanup; exit 1
fi

echo
echo "===== 2. The two addresses are what the test assumes ====="
arp=$(S $R2 "sudo /opt/vyatta/bin/vplsh -l -c 'arp show' 2>/dev/null")
if printf '%s' "$arp" | grep -q "\"ip\":\"$HIT\""; then
	ok "R2's neighbour table holds $HIT, so it can be answered"
else
	bad "R2's neighbour table holds $HIT, so it can be answered" \
	    "no entry for $HIT -- every 'suppressed' assertion below would fail for this reason"
fi
if printf '%s' "$arp" | grep -q "\"ip\":\"$MISS\""; then
	bad "R2's neighbour table does not hold $MISS" \
	    "something already holds $MISS -- the 'flooded' assertions would fail for this reason"
else
	ok "R2's neighbour table does not hold $MISS, so it cannot be answered"
fi

echo
echo "===== 3. Off: the flood happens, the counter does not ====="
st=$(supp_state)
echo "    state: $st"
if [ "$st" = unreadable ]; then
	bad "the dataplane reports its suppression state" "vplsh returned nothing parseable"
	cleanup; exit 1
fi
set -- $st
[ "$1" = "False" ] && ok "suppression starts off" || bad "suppression starts off" "enabled=$1"

measure 4 request $MISS
if [ "$d_flood" -eq 0 ] && [ "$d_supp" -eq 0 ]; then
	ok "with it off neither counter moves -- the fast path returns before them"
else
	bad "with it off neither counter moves" \
	    "suppressed +$d_supp flooded +$d_flood"
fi
if [ "$d_out" -ge 4 ]; then
	ok "and the four requests really were flooded into the fabric (OutPkts +$d_out)"
else
	bad "and the four requests really were flooded into the fabric" \
	    "OutPkts only moved +$d_out, so 'counters did not move' may mean nothing was sent"
fi

echo
echo "===== 4. Turn it on ====="
out=$(cli $R2 "set interfaces bridge br20 arp-suppression")
if [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then printf '%s\n' "$out" | sed 's/^/    /'; fi
sleep 8
st=$(supp_state); set -- $st
echo "    state: $st"
[ "$1" = "True" ] && ok "the dataplane took the configuration" || bad "the dataplane took the configuration" "enabled=$1"

echo
echo "===== 5. Nothing else in the fabric touches the counters ====="
# Every exact delta below depends on this. BGP runs over 10.60.60.0/24 on the
# underlay ports, not through br20, so the bridge domain should be silent when
# no one is asking -- but "should be" is what this step replaces.
q1=$(supp_state); sleep 12; q2=$(supp_state)
echo "    $q1  ->  $q2"
if [ "$q1" = "$q2" ]; then
	ok "twelve idle seconds move neither counter, so the deltas below are the frames sent"
else
	bad "twelve idle seconds move neither counter" \
	    "$q1 -> $q2 -- background ARP in the bridge domain makes exact deltas unusable"
fi

echo
echo "===== 6. One request in, one count out ====="
measure 5 request $MISS
exact "five unanswerable requests raise flooded by exactly five" 0 5
if [ "$d_out" -ge 5 ]; then
	ok "and each one was still flooded, so the name matches the action (OutPkts +$d_out)"
else
	bad "and each one was still flooded" "OutPkts +$d_out for five flooded requests"
fi

echo
echo "===== 7. An answerable request never reaches the counter ====="
measure 5 request $HIT
exact "five answerable requests raise suppressed by exactly five, flooded by none" 5 0
if [ "$d_out" -lt 5 ]; then
	ok "and nothing like five packets left for the fabric (OutPkts +$d_out)"
else
	bad "and nothing like five packets left for the fabric" \
	    "OutPkts +$d_out -- answered requests should not also be encapsulated"
fi

echo
echo "===== 8. A mixed burst splits with no cross-talk ====="
# Three answerable and two not, through the same bridge in the same window.
before=$(supp_state)
send 3 request $HIT > /dev/null
send 2 request $MISS > /dev/null
after=$(supp_state)
set -- $before; bs=$2; bf=$3
set -- $after;  as=$2; af=$3
d_supp=$((as - bs)); d_flood=$((af - bf))
printf '    3 answerable + 2 not   suppressed %s -> %s (%+d)   flooded %s -> %s (%+d)\n' \
       "$bs" "$as" "$d_supp" "$bf" "$af" "$d_flood"
exact "the burst splits three to two, each request counted once and in one place" 3 2

echo
echo "===== 9. What the counter does not count ====="
# Both of these flood exactly as an unanswerable request does. If either moves
# a counter, the gate in front of it is wrong -- and "flooded" would then be
# reporting broadcast volume rather than suppression misses, which is a number
# an operator would read the wrong way.
measure 4 reply $MISS
exact "ARP replies flood without touching either counter" 0 0
measure 4 other $MISS
exact "a non-ARP broadcast floods without touching either counter" 0 0

echo
echo "===== 10. The miss is temporary, not a steady state ====="
# Give $MISS to R1 and let R2 learn the binding the ordinary way. Nothing about
# the bridge, the configuration or the sender changes -- only whether the
# neighbour table can answer. That is the whole claim the counter makes.
cli $R1 "set interfaces bridge br20 address $MISS/24" | tail -1
sleep 8
S $R1 "sudo ip vrf exec vrfRED ping -c 3 -W 2 -I $MISS 10.20.20.2 >/dev/null 2>&1"
sleep 5
arp=$(S $R2 "sudo /opt/vyatta/bin/vplsh -l -c 'arp show' 2>/dev/null")
if printf '%s' "$arp" | grep -q "\"ip\":\"$MISS\""; then
	ok "R2 has now learned $MISS the ordinary way"
else
	bad "R2 has now learned $MISS the ordinary way" \
	    "still no entry -- step 10's remaining assertion cannot mean anything"
fi
measure 4 request $MISS
exact "the same address that flooded four frames ago is now answered, and stops flooding" 4 0

echo
echo "===== 11. For the record: a request for the bridge's own address ====="
# Not an assertion. A broadcast request for 10.20.20.2 is delivered to R2's own
# L3 path first and answered there, and then still falls through to the
# suppression check, where the neighbour table has no entry for an address that
# is the interface's own. Whichever way that lands, it is worth having written
# down: an operator reading a slowly rising flooded on an otherwise quiet
# bridge should know this is one of the things that can produce it.
measure 3 request 10.20.20.2
printf '    requests for the SVI itself: suppressed +%d, flooded +%d\n' "$d_supp" "$d_flood"

echo
echo "===== 12. Result ====="
printf '  %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
	echo "  THE FLOODED COUNTER MEANS WHAT IT SAYS. It counts requests the"
	echo "  neighbour table could not answer, once each, and nothing else: not"
	echo "  answered requests, not ARP replies, not other broadcasts, and not"
	echo "  anything at all while the feature is off. It stops rising for an"
	echo "  address the moment the binding arrives, which is what makes a"
	echo "  rising count a diagnosis rather than a statistic."
else
	echo "  Something above did not hold. Check step 5 first: if the fabric is"
	echo "  not quiet then every exact delta after it is measuring background"
	echo "  traffic as well as the frames sent, and the failures below it are"
	echo "  consequences rather than defects."
fi

cleanup
exit "$fail"
