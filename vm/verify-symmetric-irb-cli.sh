#!/bin/bash
# Symmetric IRB, configured entirely from the DANOS CLI.
#
# probe-symmetric-irb.sh measured the datapath with static routes.
# probe-symmetric-irb-frr.sh measured FRR driving it, through vtysh. Both
# worked, so what was missing was a model. This runs the same fabric with
# nothing typed into vtysh at all:
#
#   set routing routing-instance RED vni 5000
#   set routing routing-instance RED protocols bgp 65000 \
#       address-family ipv4-unicast redistribute connected
#   set routing routing-instance RED protocols bgp 65000 \
#       address-family l2vpn-evpn advertise-ipv4-unicast
#
# The verdict a single ping would give is not enough here, because the thing
# being tested is a chain of five handoffs and any one of them failing
# produces the same silence:
#
#   the model commits          configd accepts the shape
#   it reaches FRR             the translator emits what zebra and bgpd read
#   zebra takes the L3VNI      "5000  L3  tun5 ... vrfRED"
#   bgpd originates type-5     with the router MAC attached
#   zebra installs it          via the remote VTEP, with the RMAC as a neighbour
#   the dataplane forwards     which the earlier probes already measured
#
# Each is checked on what the box reports. The redistribute line is checked
# separately from the advertise line because without it the advertise line is
# accepted, appears in the running config, and originates nothing -- a silence
# that reads as bgpd being unable to do this.
#
#   R1  VTEP 10.60.60.1   br5 10.50.50.1/24 (tun5, VNI 5000)  transit
#                         br10 10.10.10.1/24 (dp0s3)          tenant
#   R2  VTEP 10.60.60.2   br5 10.50.50.2/24 (tun5, VNI 5000)  transit
#                         br20 10.20.20.1/24 (dp0s8)          tenant
#   R3  host 10.20.20.3/24 on dp0s8
#
# R1 never has VNI 20. That is the difference symmetric IRB exists for, and
# it is asserted rather than assumed.
#
# TOPO=ipsec wiring: R1.dp0s9 <-> R2.dp0s3, R2.dp0s8 <-> R3.dp0s8.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-symmetric-irb-cli.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.155
R2=192.168.203.156
R3=192.168.203.157
pass=0
fail=0

HERE=$(cd "$(dirname "$0")" && pwd)
exec > "$OUT" 2>&1
# Which image is this a statement about? Read from the running VMs, never
# from the variable the caller passed.
"$HERE/image-fingerprint.sh"
S() { docker exec danos-robot timeout 200 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$1" "$2" 2>&1; }
op() { S "$1" "vbash -ic '$2' 2>&1" | grep -v '^vbash: '; }

cli() {
	local h=$1; shift
	local c=""
	for x in "$@"; do c="$c vcli -s \$SID -c \"$x\" 2>&1;"; done
	S "$h" "SID=\$\$; eval \"\$(cli-shell-api getSessionEnv \$SID)\"; cli-shell-api setupSession; $c
	        vcli -s \$SID -c commit 2>&1 | grep -viE 'sssd|configuration db|grub|boot-loader|crash dump|^\s*\$'"
}

ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; shift; printf '%s\n' "$@" | head -8 | sed 's/^/        /'; fail=$((fail + 1)); }

has() {
	local what=$1 want=$2 label=$3
	if printf '%s' "$what" | grep -qE "$want"; then ok "$label"
	else bad "$label" "wanted to match: $want" "$what"; fi
}

cleanup() {
	echo; echo "===== Clean up ====="
	cli $R1 "delete routing routing-instance RED" \
	        "delete interfaces dataplane dp0s3 bridge-group" \
	        "delete interfaces tunnel tun5" \
	        "delete interfaces bridge br5" "delete interfaces bridge br10" \
	        "delete interfaces dataplane dp0s9 address 10.60.60.1/24" \
	        "delete protocols bgp 65000" > /dev/null
	cli $R2 "delete routing routing-instance RED" \
	        "delete interfaces dataplane dp0s8 bridge-group" \
	        "delete interfaces tunnel tun5" \
	        "delete interfaces bridge br5" "delete interfaces bridge br20" \
	        "delete interfaces dataplane dp0s3 address 10.60.60.2/24" \
	        "delete protocols bgp 65000" > /dev/null
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

echo "===== 1. The fabric, from the CLI only ====="
# The global BGP instance carries the EVPN session; the routing instance
# contributes its prefixes to it. Both are model, neither is vtysh.
r1out=$(cli $R1 \
  "set interfaces dataplane dp0s9 address 10.60.60.1/24" \
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
  "set routing routing-instance RED interface br10" \
  "set routing routing-instance RED vni 5000" \
  "set protocols bgp 65000 neighbor 10.60.60.2 remote-as 65000" \
  "set protocols bgp 65000 neighbor 10.60.60.2 update-source 10.60.60.1" \
  "set protocols bgp 65000 neighbor 10.60.60.2 address-family l2vpn-evpn" \
  "set protocols bgp 65000 address-family l2vpn-evpn advertise-all-vni" \
  "set routing routing-instance RED protocols bgp 65000 address-family ipv4-unicast redistribute connected" \
  "set routing routing-instance RED protocols bgp 65000 address-family l2vpn-evpn advertise-ipv4-unicast")
printf '%s\n' "$r1out" | sed 's/^/    R1: /'
if printf '%s' "$r1out" | grep -qiE 'error|invalid|not valid|failed|Validation'; then
	bad "R1 accepted the symmetric IRB configuration" "$r1out"
else
	ok "R1 accepted the symmetric IRB configuration"
fi
r2out=$(cli $R2 \
  "set interfaces dataplane dp0s3 address 10.60.60.2/24" \
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
  "set routing routing-instance RED interface br20" \
  "set routing routing-instance RED vni 5000" \
  "set protocols bgp 65000 neighbor 10.60.60.1 remote-as 65000" \
  "set protocols bgp 65000 neighbor 10.60.60.1 update-source 10.60.60.2" \
  "set protocols bgp 65000 neighbor 10.60.60.1 address-family l2vpn-evpn" \
  "set protocols bgp 65000 address-family l2vpn-evpn advertise-all-vni" \
  "set routing routing-instance RED protocols bgp 65000 address-family ipv4-unicast redistribute connected" \
  "set routing routing-instance RED protocols bgp 65000 address-family l2vpn-evpn advertise-ipv4-unicast")
printf '%s\n' "$r2out" | sed 's/^/    R2: /'
if printf '%s' "$r2out" | grep -qiE 'error|invalid|not valid|failed|Validation'; then
	bad "R2 accepted the symmetric IRB configuration" "$r2out"
else
	ok "R2 accepted the symmetric IRB configuration"
fi
# R3 is a host, not a leaf. Without a route back the return path fails and
# reads as the fabric being broken.
cli $R3 "set interfaces dataplane dp0s8 address 10.20.20.3/24" \
        "set protocols static route 10.10.10.0/24 next-hop 10.20.20.1" | tail -1

echo
echo "===== 2. What the model emitted ====="
frr=$(S $R1 'sudo vtysh -c "show running-config" 2>/dev/null')
printf '%s' "$frr" | sed -n '/^vrf vrfRED/,/exit-vrf/p' | sed 's/^/    /'
printf '%s' "$frr" | sed -n '/^router bgp 65000 vrf vrfRED/,/^exit$/p' | sed 's/^/    /'
has "$frr" '^vrf vrfRED'                    "the vrf block is in frr.conf"
# An empty vrf block -- the opener and exit-vrf with nothing between -- is the
# signature of the YANG module not being listed in the FRR component's
# manifest. configd accepts the leaf, it is in the configuration tree, and the
# component never receives it, so the translator has nothing to emit. The
# block that remains comes from protocols/next-hop, which shares the same
# opener.
has "$frr" '^ vni 5000'                     "the L3VNI reached zebra"
has "$frr" 'router bgp 65000 vrf vrfRED'    "the instance has its own BGP"
has "$frr" 'redistribute connected'         "the tenant prefixes are redistributed"
has "$frr" 'advertise ipv4 unicast'         "and advertised as type-5"

if [ "$fail" -ne 0 ]; then
	echo
	echo "  Not continuing: the configuration did not reach FRR, so nothing"
	echo "  below would be measuring symmetric IRB."
	cleanup
	exit "$fail"
fi

echo
echo "===== 3. zebra takes it as an L3VNI ====="
sleep 55
vni=$(S $R1 'sudo vtysh -c "show evpn vni" 2>&1')
printf '%s\n' "$vni" | head -4 | sed 's/^/    /'
has "$vni" '^5000 +L3 +tun5.*vrfRED'  "VNI 5000 is L3, bound to vrfRED"

echo
echo "===== 4. The type-5 route, with the router MAC ====="
t5=$(S $R1 'sudo vtysh -c "show bgp l2vpn evpn route type prefix" 2>&1')
printf '%s\n' "$t5" | grep -A2 "10.20.20.0" | head -4 | sed 's/^/    /'
has "$t5" '\[5\]:\[0\]:\[24\]:\[10\.20\.20\.0\]'  "R1 received a type-5 for the far tenant subnet"
has "$t5" 'Rmac:'                                 "it carries a router MAC"

echo
echo "===== 5. Installed, with the router MAC as a neighbour ====="
rt=$(op $R1 "show ip route routing-instance RED")
printf '%s\n' "$rt" | grep -E "^B" | sed 's/^/    /'
has "$rt" '^B>\* 10\.20\.20\.0/24 .*via 10\.60\.60\.2, br5'  "the route points at the far VTEP over the transit bridge"
nb=$(S $R1 "ip neigh show dev br5 2>/dev/null")
printf '%s\n' "$nb" | sed 's/^/    /' | head -3
has "$nb" '10\.60\.60\.2 lladdr .* extern_learn'  "the far leaf's router MAC is installed as a neighbour"

echo
echo "===== 6. R1 holds no VNI 20 ====="
# The whole reason for symmetric IRB. If R1 had that bridge domain this would
# be the asymmetric arrangement wearing a transit VNI.
brs=$(S $R1 "ip -br link show type bridge 2>/dev/null | awk '{print \$1}'")
printf '    %s\n' "$(printf '%s' "$brs" | tr '\n' ' ')"
if printf '%s' "$brs" | grep -q "br20"; then
	bad "R1 has no bridge for the far tenant subnet" "br20 is present on R1"
else
	ok "R1 has no bridge for the far tenant subnet"
fi

echo
echo "===== 7. It forwards, routed at both ends ====="
got=$(S $R1 "sudo ip vrf exec vrfRED ping -c 4 -W 3 -I 10.10.10.1 10.20.20.3 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | tr -dc '0-9')
if [ "${got:-0}" -ge 3 ]; then ok "R1's tenant reaches R3: $got of 4"
else bad "R1's tenant reaches R3" "got $got of 4"; fi
hop=$(S $R1 "sudo ip vrf exec vrfRED traceroute -n -w 2 -q 1 -m 4 -s 10.10.10.1 10.20.20.3 2>&1 | head -4")
printf '%s\n' "$hop" | sed 's/^/    /'
has "$hop" '1 +10\.50\.50\.2'   "first hop is the far leaf's transit address"
has "$hop" '2 +10\.20\.20\.3'   "second hop is the host, so both ends routed"

echo
echo "===== 8. Result ====="
printf '  %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
	echo "  SYMMETRIC IRB IS CONFIGURABLE FROM THE CLI. The model emits what"
	echo "  zebra and bgpd read, the type-5 route arrives with a router MAC,"
	echo "  it is installed against the remote VTEP, and traffic takes the two"
	echo "  routed hops it should -- with the ingress leaf holding none of the"
	echo "  destination's bridge domain."
else
	echo "  Something above did not hold. A vrf block with nothing in it at"
	echo "  step 2 means vyatta-protocols-frr-evpn-l3vni-v1 is missing from"
	echo "  Modules= in debian/vyatta-frr-vci.component: the leaf commits, and"
	echo "  the component it belongs to never hears about it."
	echo
	echo "  An empty step 4 with step 2 clean is"
	echo "  almost always redistribute connected missing on the far leaf:"
	echo "  advertise-ipv4-unicast advertises the instance's BGP IPv4 table,"
	echo "  not its routing table, and originates nothing without it."
fi

cleanup
exit "$fail"
