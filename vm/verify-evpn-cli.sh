#!/bin/bash
# Does the EVPN configuration model actually work from the CLI?
#
# Everything that proved EVPN forwards was typed into vtysh. The model exists
# so it need not be, and three things have to hold for that to be true:
#
#   1. the configuration commits              -- YANG accepts the shape
#   2. it reaches FRR                         -- the translator emits the right
#                                                commands and vtysh has them
#   3. it does the same thing vtysh did       -- the session comes up, the MAC
#                                                is advertised, it is learned
#
# and a fourth that is not about EVPN at all:
#
#   4. the show commands run                  -- opd positional arguments are
#                                                counted by hand and are off by
#                                                one until something runs them
#
# Point 4 is why this script exists rather than a pyang run. pyang validates
# both modules with every $N wrong: the number only matters when the CLI
# substitutes it, and then the command silently asks vtysh about the wrong
# thing. Every show command below is run and its output inspected, not merely
# invoked for an exit status -- "show evpn vni" with a missing argument still
# exits 0.
#
#   R1  VTEP 10.60.60.1, br0 = tun0 only
#   R2  VTEP 10.60.60.2, br0 = tun0 + dp0s8,  R3 behind it
#
# TOPO=ipsec wiring: R1.dp0s9 <-> R2.dp0s3, R2.dp0s8 <-> R3.dp0s8.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-evpn-cli.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.155
R2=192.168.203.156
R3=192.168.203.157
pass=0
fail=0

exec > "$OUT" 2>&1
S() { docker exec danos-robot timeout 200 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$1" "$2" 2>&1; }

# Returns the commit output so a rejected set is visible rather than assumed.
cli() {
	local h=$1; shift
	local c=""
	for x in "$@"; do c="$c vcli -s \$SID -c \"$x\" 2>&1;"; done
	S "$h" "SID=\$\$; eval \"\$(cli-shell-api getSessionEnv \$SID)\"; cli-shell-api setupSession; $c
	        vcli -s \$SID -c commit 2>&1 | grep -viE 'sssd|configuration db|grub|boot-loader|crash dump|^\s*\$'"
}

# Operational commands run in the login shell, not through vcli. vcli is the
# configuration client: given an operational command it prints nothing and
# exits 0, so the first version of this script reported all nine show commands
# as broken when what was broken was the way it called them. "show version"
# came back empty too, which is the check that settled it.
#
# vbash writes two job-control lines to stderr when it is not on a terminal.
# They are noise from the harness, not from the command.
op() {
	S "$1" "vbash -ic '$2' 2>&1" | grep -v '^vbash: '
}

# An operational command is only proven by what it prints. Checking the exit
# status proves the shell ran vtysh, which it does even when the command it
# passed on was nonsense.
check_op() {
	local host=$1 cmd=$2 want=$3 label=$4 got
	got=$(op "$host" "$cmd")
	if printf '%s' "$got" | grep -qiE "$want"; then
		printf '  PASS  %s\n' "$label"
		pass=$((pass + 1))
	else
		printf '  FAIL  %s\n' "$label"
		printf '        ran: %s\n' "$cmd"
		printf '        wanted to match: %s\n' "$want"
		printf '%s\n' "$got" | head -6 | sed 's/^/        got: /'
		fail=$((fail + 1))
	fi
}

check_contains() {
	local what=$1 want=$2 label=$3
	if printf '%s' "$what" | grep -qiE "$want"; then
		printf '  PASS  %s\n' "$label"
		pass=$((pass + 1))
	else
		printf '  FAIL  %s\n' "$label"
		printf '        wanted to match: %s\n' "$want"
		printf '%s\n' "$what" | head -10 | sed 's/^/        got: /'
		fail=$((fail + 1))
	fi
}

check_absent() {
	local what=$1 unwanted=$2 label=$3
	if printf '%s' "$what" | grep -qiE "$unwanted"; then
		printf '  FAIL  %s\n' "$label"
		printf '        should not have matched: %s\n' "$unwanted"
		printf '%s\n' "$what" | grep -iE "$unwanted" | head -4 | sed 's/^/        got: /'
		fail=$((fail + 1))
	else
		printf '  PASS  %s\n' "$label"
		pass=$((pass + 1))
	fi
}

cleanup() {
	echo; echo "===== Clean up ====="
	cli $R1 "delete protocols bgp 65000" "delete interfaces tunnel tun0" \
	        "delete interfaces bridge br0" \
	        "delete interfaces dataplane dp0s9 address 10.60.60.1/24" > /dev/null
	cli $R2 "delete protocols bgp 65000" "delete interfaces dataplane dp0s8 bridge-group" \
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

echo "===== 1. Underlay and the bridge domain ====="
cli $R1 "set interfaces dataplane dp0s9 address 10.60.60.1/24" \
        "set interfaces tunnel tun0 encapsulation vxlan" \
        "set interfaces tunnel tun0 vxlan-id 100" \
        "set interfaces tunnel tun0 local-ip 10.60.60.1" \
        "set interfaces tunnel tun0 remote-ip 10.60.60.2" \
        "set interfaces bridge br0" \
        "set interfaces bridge br0 address 10.61.61.1/24" \
        "set interfaces tunnel tun0 bridge-group bridge br0" | tail -2
cli $R2 "set interfaces dataplane dp0s3 address 10.60.60.2/24" \
        "set interfaces tunnel tun0 encapsulation vxlan" \
        "set interfaces tunnel tun0 vxlan-id 100" \
        "set interfaces tunnel tun0 local-ip 10.60.60.2" \
        "set interfaces tunnel tun0 remote-ip 10.60.60.1" \
        "set interfaces bridge br0" \
        "set interfaces bridge br0 address 10.61.61.2/24" \
        "set interfaces tunnel tun0 bridge-group bridge br0" \
        "set interfaces dataplane dp0s8 bridge-group bridge br0" | tail -2
cli $R3 "set interfaces dataplane dp0s8 address 10.61.61.3/24" | tail -2
sleep 12
MAC3=$(S $R3 "cat /sys/class/net/dp0s8/address" | tail -1)
echo "  R3 dp0s8 MAC: $MAC3"

echo; echo "===== 2. EVPN entirely from the configuration ====="
r1out=$(cli $R1 \
  "set protocols bgp 65000 neighbor 10.60.60.2 remote-as 65000" \
  "set protocols bgp 65000 neighbor 10.60.60.2 update-source 10.60.60.1" \
  "set protocols bgp 65000 neighbor 10.60.60.2 address-family l2vpn-evpn" \
  "set protocols bgp 65000 address-family l2vpn-evpn advertise-all-vni")
printf '%s\n' "$r1out" | sed 's/^/    R1: /'
check_absent "$r1out" 'error|invalid|not valid|failed|Validation' "R1 accepted the EVPN configuration"
r2out=$(cli $R2 \
  "set protocols bgp 65000 neighbor 10.60.60.1 remote-as 65000" \
  "set protocols bgp 65000 neighbor 10.60.60.1 update-source 10.60.60.2" \
  "set protocols bgp 65000 neighbor 10.60.60.1 address-family l2vpn-evpn" \
  "set protocols bgp 65000 address-family l2vpn-evpn advertise-all-vni")
printf '%s\n' "$r2out" | sed 's/^/    R2: /'
check_absent "$r2out" 'error|invalid|not valid|failed|Validation' "R2 accepted the EVPN configuration"

echo; echo "===== 3. What reached FRR ====="
frr=$(S $R1 'sudo vtysh -c "show running-config" 2>/dev/null | sed -n "/router bgp/,/^!/p"')
printf '%s\n' "$frr" | sed 's/^/    /'
check_contains "$frr" 'address-family l2vpn evpn' "the address family block is in frr.conf"
check_contains "$frr" 'neighbor 10\.60\.60\.2 activate' "the neighbour is activated for it"
check_contains "$frr" 'advertise-all-vni'            "advertise-all-vni reached FRR"

echo; echo "===== 4. Does it do what vtysh did ====="
S $R2 "ping -c 3 -W 2 10.61.61.3 >/dev/null 2>&1"   # give R2 a local MAC to advertise
sleep 45
summary=$(S $R1 'sudo vtysh -c "show bgp l2vpn evpn summary" 2>&1')
check_contains "$summary" '10\.60\.60\.2' "R1 has an EVPN session with R2"
# "(Policy)" in place of a prefix count is ebgp-requires-policy; Idle, Active
# and Connect are a session that never came up. Either would let the MAC check
# below fail for a reason that has nothing to do with the model.
check_absent "$summary" '\(Policy\)|\b(Idle|Active|Connect)\b' \
	"the EVPN session is established and exchanging"
learned=$(S $R1 "sudo vtysh -c 'show evpn mac vni 100' 2>&1")
check_contains "$learned" "$MAC3" "R1 learned R3's MAC through the configured session"

echo; echo "===== 5. The show commands, which is where \$N goes wrong ====="
# Each wants a string the real command prints and a wrong $N cannot produce.
check_op $R1 "show protocols bgp l2vpn evpn summary"  '10\.60\.60\.2'          "show protocols bgp l2vpn evpn summary"
check_op $R1 "show protocols bgp l2vpn evpn vni"      'VNI|Number of|[0-9]{2,}' "show protocols bgp l2vpn evpn vni"
check_op $R1 "show protocols bgp l2vpn evpn vni 100"  'VNI: 100|100'            "show protocols bgp l2vpn evpn vni <id>  (positional)"
check_op $R1 "show protocols bgp l2vpn evpn import-rt" 'Import RTs|RT|[0-9]+:'  "show protocols bgp l2vpn evpn import-rt"
check_op $R1 "show protocols evpn vni"                'VNI|100'                 "show protocols evpn vni"
check_op $R1 "show protocols evpn vni 100"            'VNI: 100|Type: L2|100'   "show protocols evpn vni <id>  (positional)"
check_op $R1 "show protocols evpn mac vni 100"        "$MAC3"                   "show protocols evpn mac vni <id>  (positional)"
check_op $R1 "show protocols evpn mac vni all"        "$MAC3"                   "show protocols evpn mac vni all"
check_op $R1 "show protocols evpn arp-cache vni 100"  'ARP|Neighbor|IP|Number'  "show protocols evpn arp-cache vni <id>  (positional)"

echo; echo "===== 6. Per-VNI overrides ====="
# The route targets are 65000:777, not 65000:100, and the difference decides
# whether this section measures anything. FRR derives a VNI's route target
# from the AS and the VNI, so for VNI 100 in AS 65000 the derived value is
# exactly 65000:100: configuring it is a no-op, FRR stores nothing, and it
# never appears in the running config. The first version of this check asked
# for a line the system was entitled not to produce and called the model
# broken when it was not.
vniout=$(cli $R1 \
  "set protocols bgp 65000 address-family l2vpn-evpn vni 100 rd 65000:100" \
  "set protocols bgp 65000 address-family l2vpn-evpn vni 100 route-target import 65000:777" \
  "set protocols bgp 65000 address-family l2vpn-evpn vni 100 route-target export 65000:777")
printf '%s\n' "$vniout" | sed 's/^/    /'
sleep 12
frr2=$(S $R1 'sudo vtysh -c "show running-config" 2>/dev/null | sed -n "/router bgp/,/^exit$/p"')
check_contains "$frr2" 'vni 100'                      "the per-VNI block reached FRR"
check_contains "$frr2" 'rd 65000:100'                 "the route distinguisher reached FRR"
check_contains "$frr2" 'route-target import 65000:777' "the import route target reached FRR"
check_contains "$frr2" 'route-target export 65000:777' "the export route target reached FRR"

echo; echo "===== 7. Rejecting what should be rejected ====="
bad=$(cli $R1 "set protocols bgp 65000 address-family l2vpn-evpn vni 100 rd not-an-rd")
check_contains "$bad" 'Route distinguisher must be|invalid|not valid|Validation' \
	"a malformed route distinguisher is refused"
cli $R1 "delete protocols bgp 65000 address-family l2vpn-evpn vni 100 rd not-an-rd" > /dev/null 2>&1

echo; echo "===== 8. Result ====="
printf '  %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
	echo "  EVPN IS CONFIGURABLE FROM THE CLI. The model commits, the"
	echo "  translator emits what FRR expects, the session carries MACs, and"
	echo "  every show command printed what it was asked for."
else
	echo "  Something above did not hold. Two readings before blaming the"
	echo "  model, because both have already been the answer once:"
	echo
	echo "  If a show command returned nothing at all -- including one that"
	echo "  takes no argument -- the command was not run. Check that"
	echo "  \"show version\" comes back through the same path; if that is"
	echo "  empty too, the harness is at fault, not the model."
	echo
	echo "  If a show command returned the wrong thing, it is an opd"
	echo "  positional argument. The count runs from \"show\", so in"
	echo "  \"show protocols evpn mac vni <id>\" the id is the sixth token;"
	echo "  any other number asks vtysh a different question and exits 0."
fi

cleanup
exit "$fail"
