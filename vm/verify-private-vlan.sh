#!/bin/bash
# Private VLAN: do the port roles actually restrict forwarding?
#
# R2 bridges its two dataplane ports, putting R1 and R3 on one L2 segment
# through it. verify-bridge-viability.sh established that this forwards at all
# -- 4 of 4 -- which is the baseline every case here is measured against.
#
#   R1 dp0s9 10.50.50.1/24 --- dp0s3 [ R2  br0 ] dp0s8 --- dp0s8 10.50.50.3/24 R3
#
# The two enforcement points are tested separately, and that separation is the
# whole design of this script. A ping needs ARP first, ARP is broadcast, and
# broadcast goes through the flood path. So "both isolated, ping fails" passes
# whether or not the unicast guard exists -- an implementation with only the
# flood guard would look complete. To tell them apart:
#
#   flood path    unresolved ARP, with no static entry to short-circuit it
#   unicast path  static ARP on both hosts and the bridge's MAC table already
#                 populated, so the frame is known-unicast from the first packet
#
# TOPO=ipsec wiring: R1.dp0s9 <-> R2.dp0s3, R2.dp0s8 <-> R3.dp0s8.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-private-vlan.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.155
R2=192.168.203.156
R3=192.168.203.157
P1=dp0s3          # R2's port facing R1
P3=dp0s8          # R2's port facing R3

exec > "$OUT" 2>&1
S() { docker exec danos-robot timeout 200 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$1" "$2" 2>&1; }

cli() {
	local h=$1; shift
	local c=""
	for x in "$@"; do c="$c vcli -s \$SID -c \"$x\" 2>&1;"; done
	S "$h" "SID=\$\$; eval \"\$(cli-shell-api getSessionEnv \$SID)\"; cli-shell-api setupSession; $c
	        vcli -s \$SID -c commit 2>&1 | grep -viE 'sssd|configuration db|grub|boot-loader|crash dump|^\s*\$' | tail -2"
}

role() {   # port role [community]
	if [ -n "${3:-}" ]; then
		cli $R2 "set interfaces dataplane $1 bridge-group private-vlan port-role $2" \
		        "set interfaces dataplane $1 bridge-group private-vlan community $3" > /dev/null
	else
		cli $R2 "delete interfaces dataplane $1 bridge-group private-vlan community" \
		        "set interfaces dataplane $1 bridge-group private-vlan port-role $2" > /dev/null
	fi
}

horizon() {
	S $R2 "sudo /opt/vyatta/bin/vplsh -l -c 'bridge br0 horizon'" \
	  | grep -oE '"port":"[^"]*","group":[0-9]+,"intra_allow":(true|false),"role":"[a-z]*"' \
	  | sed 's/^/    /'
}

ping_flood() {   # ARP has to resolve, so this exercises the flood path
	S $R1 "sudo ip neigh flush dev dp0s9 2>/dev/null
	       ping -c 3 -W 2 10.50.50.3 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | tr -dc '0-9'
}

ping_unicast() { # static ARP, so the first frame is known unicast
	S $R1 "sudo ip neigh replace 10.50.50.3 lladdr $MAC3 dev dp0s9 2>/dev/null
	       ping -c 3 -W 2 10.50.50.3 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | tr -dc '0-9'
}

pass_fail() {   # got want-label
	local got=$1 want=$2
	if [ "$want" = reach ]; then
		[ "${got:-0}" -ge 2 ] && echo PASS || echo "FAIL (got ${got:-?}/3, wanted traffic)"
	else
		[ "${got:-9}" -eq 0 ] && echo PASS || echo "FAIL (got ${got:-?}/3, wanted none)"
	fi
}

case_is() {   # label r1role r3role want [c1] [c3]
	local label=$1 r1r=$2 r3r=$3 want=$4 c1=${5:-} c3=${6:-}
	role $P1 "$r1r" "$c1"
	role $P3 "$r3r" "$c3"
	sleep 6
	local f u
	f=$(ping_flood); u=$(ping_unicast)
	printf '  %-34s flood=%-3s %-28s unicast=%-3s %s\n' \
		"$label" "${f:-?}/3" "$(pass_fail "$f" "$want")" \
		"${u:-?}/3" "$(pass_fail "$u" "$want")"
}

echo "===== 1. Bridge R1 and R3 through R2 ====="
cli $R1 "set interfaces dataplane dp0s9 address 10.50.50.1/24" > /dev/null
cli $R3 "set interfaces dataplane dp0s8 address 10.50.50.3/24" > /dev/null
cli $R2 "set interfaces bridge br0" \
        "set interfaces dataplane $P1 bridge-group bridge br0" \
        "set interfaces dataplane $P3 bridge-group bridge br0" > /dev/null
sleep 10
MAC3=$(S $R3 "cat /sys/class/net/dp0s8/address" | tail -1)
echo "  R3 dp0s8 MAC: $MAC3"
printf '  baseline, no roles: flood=%s/3 unicast=%s/3   (both must reach)\n' \
	"$(ping_flood)" "$(ping_unicast)"

echo; echo "===== 2. The matrix ====="
echo "  Each line configures both ports, then measures the two paths separately."
case_is "promiscuous <-> promiscuous" promiscuous promiscuous reach
case_is "isolated    <-> isolated"    isolated    isolated    block
case_is "isolated    <-> promiscuous" isolated    promiscuous reach
case_is "community 5 <-> community 5" community   community   reach 5 5
case_is "community 5 <-> community 6" community   community   block 5 6
case_is "community 5 <-> isolated"    community   isolated    block 5

echo; echo "===== 3. What the dataplane holds ====="
role $P1 isolated
role $P3 community 5
sleep 5
horizon

echo; echo "===== 4. Removing the configuration restores forwarding ====="
cli $R2 "delete interfaces dataplane $P1 bridge-group private-vlan" \
        "delete interfaces dataplane $P3 bridge-group private-vlan" > /dev/null
sleep 6
printf '  after delete: flood=%s/3 unicast=%s/3   (both must reach)\n' \
	"$(ping_flood)" "$(ping_unicast)"
horizon

echo; echo "===== 5. Clean up ====="
# Leave the routers as they were found. Twice now, state left behind by a
# verification has been read as a regression by the next suite to run.
cli $R2 "delete interfaces dataplane $P1 bridge-group" \
        "delete interfaces dataplane $P3 bridge-group" \
        "delete interfaces bridge br0" > /dev/null
cli $R1 "delete interfaces dataplane dp0s9 address 10.50.50.1/24" > /dev/null
cli $R3 "delete interfaces dataplane dp0s8 address 10.50.50.3/24" > /dev/null
sleep 6
S $R2 'printf "  br0 gone: %s\n" "$(ip link show br0 >/dev/null 2>&1 && echo no || echo yes)"' | tail -1
