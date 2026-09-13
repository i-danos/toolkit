#!/bin/bash
# Can FRR drive symmetric IRB here, or only the dataplane follow it?
#
# probe-symmetric-irb.sh showed the datapath working with static routes
# standing in for EVPN type-5 routes. That substitution is the remaining
# question, and it has three parts, each of which can fail on its own:
#
#   1. does zebra accept a VNI as a VRF's L3VNI          "vrf vrfRED / vni 5000"
#   2. does bgpd originate a type-5 route for the VRF's  "advertise ipv4 unicast"
#      local prefixes, over a VRF ipv4 table that has them
#
# Part 2 needs both halves. "advertise ipv4 unicast" advertises what is in the
# VRF's BGP IPv4 unicast RIB, and a connected subnet is not there until
# "redistribute connected" puts it there. Without that the command is
# accepted, the running config shows it, and no type-5 is ever originated --
# which reads as bgpd being unable to do this rather than as bgpd having
# nothing to advertise.
#   3. does zebra install a received type-5 with a next  the only one that
#      hop across the L3VNI, and does it forward         needs the dataplane
#
# They are checked separately because a single verdict would be useless: if
# nothing forwards, "FRR cannot do symmetric IRB" is true of one of these and
# not the others, and which one decides whether the work is configuration,
# packaging, or a dataplane gap after all.
#
# Configured through vtysh, not the DANOS model, which has no words for any of
# it yet. What this establishes is whether the model would have anything to
# model.
#
#   R1  VTEP 10.60.60.1   br5 10.50.50.1/24 (tun5, VNI 5000) transit
#                         br10 10.10.10.1/24 (dp0s3)         tenant
#   R2  VTEP 10.60.60.2   br5 10.50.50.2/24 (tun5, VNI 5000) transit
#                         br20 10.20.20.1/24 (dp0s8)         tenant
#   R3  host 10.20.20.3/24 on dp0s8
#
# No static route between the tenants this time. If 10.20.20.0/24 appears in
# R1's table it came from BGP, which is the whole point. R3 does get one back
# towards 10.10.10.0/24 -- it is a host, not a leaf, and without it the return
# path fails and reads as the fabric being broken.
#
# TOPO=ipsec wiring: R1.dp0s9 <-> R2.dp0s3, R2.dp0s8 <-> R3.dp0s8.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/probe-symmetric-irb-frr.log}
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

# Configure FRR and report what it said, rather than discarding it. A rejected
# line here is the answer to the whole probe.
vty() {
	local h=$1; shift
	local args=""
	for x in "$@"; do args="$args -c \"$x\""; done
	S "$h" "sudo vtysh $args 2>&1 | grep -vE '^\\s*$'"
}

cleanup() {
	echo; echo "===== Clean up ====="
	for h in $R1 $R2; do
		S "$h" 'sudo vtysh -c "configure terminal" -c "no router bgp 65000 vrf vrfRED" -c "end" >/dev/null 2>&1
		        sudo vtysh -c "configure terminal" -c "no router bgp 65000" -c "end" >/dev/null 2>&1
		        sudo vtysh -c "configure terminal" -c "vrf vrfRED" -c "no vni 5000" -c "end" >/dev/null 2>&1' > /dev/null
	done
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
		S "$h" 'printf "  tun5 %s  br5 %s  RED %s  bgp %s\n" \
		          "$(ip link show tun5 >/dev/null 2>&1 && echo LEFT || echo gone)" \
		          "$(ip link show br5 >/dev/null 2>&1 && echo LEFT || echo gone)" \
		          "$(ip link show vrfRED >/dev/null 2>&1 && echo LEFT || echo gone)" \
		          "$(sudo vtysh -c "show running-config" 2>/dev/null | grep -c "router bgp")"' | tail -1
	done
}

echo "===== 1. The same topology, no static route between tenants ====="
cli $R1 "set interfaces dataplane dp0s9 address 10.60.60.1/24" \
        "set interfaces tunnel tun5 encapsulation vxlan" \
        "set interfaces tunnel tun5 vxlan-id 5000" \
        "set interfaces tunnel tun5 local-ip 10.60.60.1" \
        "set interfaces tunnel tun5 remote-ip 10.60.60.2" \
        "set interfaces bridge br5" "set interfaces bridge br5 address 10.50.50.1/24" \
        "set interfaces tunnel tun5 bridge-group bridge br5" \
        "set interfaces bridge br10" "set interfaces bridge br10 address 10.10.10.1/24" \
        "set interfaces dataplane dp0s3 bridge-group bridge br10" \
        "set routing routing-instance RED" \
        "set routing routing-instance RED interface br5" \
        "set routing routing-instance RED interface br10" | tail -2
cli $R2 "set interfaces dataplane dp0s3 address 10.60.60.2/24" \
        "set interfaces tunnel tun5 encapsulation vxlan" \
        "set interfaces tunnel tun5 vxlan-id 5000" \
        "set interfaces tunnel tun5 local-ip 10.60.60.2" \
        "set interfaces tunnel tun5 remote-ip 10.60.60.1" \
        "set interfaces bridge br5" "set interfaces bridge br5 address 10.50.50.2/24" \
        "set interfaces tunnel tun5 bridge-group bridge br5" \
        "set interfaces bridge br20" "set interfaces bridge br20 address 10.20.20.1/24" \
        "set interfaces dataplane dp0s8 bridge-group bridge br20" \
        "set routing routing-instance RED" \
        "set routing routing-instance RED interface br5" \
        "set routing routing-instance RED interface br20" | tail -2
cli $R3 "set interfaces dataplane dp0s8 address 10.20.20.3/24" \
        "set protocols static route 10.10.10.0/24 next-hop 10.20.20.1" | tail -2
sleep 18

echo
echo "===== 2. Does zebra take the VNI as the VRF's L3VNI ====="
for h in $R1 $R2; do
	out=$(vty "$h" "configure terminal" "vrf vrfRED" "vni 5000" "end")
	[ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ] && printf '%s\n' "$out" | sed "s/^/    ${h##*.}: /"
done
sleep 8
echo "  (read after BGP, below: zebra populates the VNI table only once EVPN"
echo "   is active, so looking here shows nothing either way)"

echo
echo "===== 3. Does bgpd originate a type-5 for the tenant prefix ====="
for h in $R1 $R2; do
	peer=10.60.60.2; me=10.60.60.1
	[ "$h" = "$R2" ] && { peer=10.60.60.1; me=10.60.60.2; }
	out=$(vty "$h" "configure terminal" \
	     "router bgp 65000" \
	     "neighbor $peer remote-as 65000" \
	     "neighbor $peer update-source $me" \
	     "address-family l2vpn evpn" \
	     "neighbor $peer activate" \
	     "advertise-all-vni" \
	     "exit-address-family" \
	     "exit" \
	     "router bgp 65000 vrf vrfRED" \
	     "address-family ipv4 unicast" \
	     "redistribute connected" \
	     "exit-address-family" \
	     "address-family l2vpn evpn" \
	     "advertise ipv4 unicast" \
	     "end")
	[ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ] && printf '%s\n' "$out" | sed "s/^/    ${h##*.}: /"
done
sleep 55
echo "  R1's VNI table -- an L3 line is zebra accepting the L3VNI:"
S $R1 'sudo vtysh -c "show evpn vni" 2>&1 | head -5' | sed 's/^/    /'
echo "  the EVPN session:"
S $R1 'sudo vtysh -c "show bgp l2vpn evpn summary" 2>&1 | grep -E "^10\." | head -2' | sed 's/^/    /'
echo "  R2's EVPN table, type-5 routes it originated:"
S $R2 'sudo vtysh -c "show bgp l2vpn evpn route type prefix" 2>&1 | head -14' | sed 's/^/    /'

echo
echo "===== 4. Does R1 receive it and install it ====="
echo "  R1's EVPN table:"
S $R1 'sudo vtysh -c "show bgp l2vpn evpn route type prefix" 2>&1 | head -14' | sed 's/^/    /'
echo "  R1's RED routing table -- anything here for 10.20.20.0/24 came from BGP:"
S $R1 'sudo vtysh -c "show ip route vrf vrfRED" 2>&1 | grep -E "^[BCLS]" | head -8' | sed 's/^/    /'
echo "  and the kernel's:"
S $R1 "ip route show vrf vrfRED 2>/dev/null | head -6" | sed 's/^/    /'

echo
echo "===== 5. Does it forward ====="
got=$(S $R1 "sudo ip vrf exec vrfRED ping -c 4 -W 3 -I 10.10.10.1 10.20.20.3 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | tr -dc '0-9')
printf '  R1 10.10.10.1 -> R3 10.20.20.3: %s of 4  %s\n' "${got:-?}" \
	"$([ "${got:-0}" -ge 3 ] && echo 'FRR drives symmetric IRB end to end' || echo 'it does not')"
if [ "${got:-0}" -ge 3 ]; then
	echo "  path:"
	S $R1 "sudo ip vrf exec vrfRED traceroute -n -w 2 -q 1 -m 4 -s 10.10.10.1 10.20.20.3 2>&1 | head -4" | sed 's/^/    /'
fi

echo
echo "===== 6. Reading ====="
echo "  Step 2 failing means zebra will not treat the VNI as an L3VNI, and"
echo "  nothing after it can work. Step 3 failing with step 2 clean means"
echo "  bgpd is not originating type-5 routes -- a bgpd configuration or"
echo "  build question, not a dataplane one. Step 4 failing with step 3 clean"
echo "  means the route is advertised and not installed, which is zebra and"
echo "  the kernel. Only step 5 failing while 4 is clean would point back at"
echo "  the dataplane, which probe-symmetric-irb.sh has already measured"
echo "  following such a route when a static one supplied it."

cleanup
