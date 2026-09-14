#!/bin/bash
# Why did the guard for the bridge's own address not fire?
#
# bridge_arp_suppress() now returns early when ifa_is_local(brif, taddr) says
# the target is one of the bridge's own addresses. The image carries that code
# -- the shipped binary's build-id matches the OBS build whose debug symbols
# contain ifa_is_local -- and the counter still moved by exactly three for
# three requests aimed at the bridge's own SVI address.
#
# Two things could produce that, and they want opposite fixes:
#
#   A  the dataplane's bridge ifnet does not hold the address at all, so
#      if_addrhead is empty and any interface-scoped test returns false. The
#      address would then live only on the kernel's shadow device, and ARP for
#      it would be answered by Linux after the punt rather than by the
#      dataplane's own ARP path.
#
#   B  it holds the address, and something about the comparison is wrong.
#
# A is checkable directly: "ifconfig <br>" prints the address list from exactly
# the field ifa_is_local() walks (show_address() in commands.c, over
# ifp->if_addrhead). If that list is empty while the CLI shows the address
# configured, the answer is A and the guard needs a different source of truth.
#
# The same question is asked of a dataplane port for contrast. If the port has
# its address in the dataplane and the bridge does not, the difference is about
# bridges rather than about netlink or this image.
#
# TOPO=ipsec wiring: R2.dp0s8 <-> R3.dp0s8. Only R2 is touched.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/probe-bridge-svi-address.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
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

echo "===== 1. A bridge with an address and a member port ====="
# The member port matters: a bridge with no port has no carrier, the kernel
# holds it down, and a down interface is a different experiment from the one
# intended. That trap has been hit twice in this toolkit.
cli $R2 "set interfaces bridge br20" \
        "set interfaces bridge br20 address 10.20.20.2/24" \
        "set interfaces dataplane dp0s8 bridge-group bridge br20" \
        "set interfaces dataplane dp0s3 address 10.60.60.2/24" | tail -2
cli $R3 "set interfaces dataplane dp0s8 address 10.20.20.3/24" | tail -1
sleep 12

echo
echo "===== 2. What the kernel says ====="
S $R2 "ip -br addr show br20; ip -br addr show dp0s3" | sed 's/^/    /'

echo
echo "===== 3. What the dataplane says about the bridge ====="
S $R2 "sudo /opt/vyatta/bin/vplsh -l -c 'ifconfig br20' 2>&1 | head -c 900" | sed 's/^/    /'

echo
echo "===== 4. What the dataplane says about a plain port, for contrast ====="
S $R2 "sudo /opt/vyatta/bin/vplsh -l -c 'ifconfig dp0s3' 2>&1 | head -c 900" | sed 's/^/    /'

echo
echo "===== 5. Does the bridge answer ARP for its own address at all? ====="
# If the dataplane holds no address for br20 then arp_ignore() cannot match
# either, and whatever answers R3 is the kernel after the punt.
S $R3 "sudo ip -4 neigh del 10.20.20.2 dev dp0s8 2>/dev/null
       ping -c 2 -W 3 10.20.20.2 2>&1 | tail -2
       ip -4 neigh show dev dp0s8 | grep 10.20.20.2" | sed 's/^/    /'

echo
echo "===== 6. The neighbour table the guard falls through to ====="
S $R2 "sudo /opt/vyatta/bin/vplsh -l -c 'arp show' 2>&1 | head -c 600" | sed 's/^/    /'

echo
echo "===== Clean up ====="
cli $R2 "delete interfaces dataplane dp0s8 bridge-group" \
        "delete interfaces bridge br20" \
        "delete interfaces dataplane dp0s3 address 10.60.60.2/24" > /dev/null
cli $R3 "delete interfaces dataplane dp0s8 address 10.20.20.3/24" > /dev/null
sleep 5
S $R2 'printf "  br20 %s\n" "$(ip link show br20 >/dev/null 2>&1 && echo LEFT || echo gone)"' | tail -1
