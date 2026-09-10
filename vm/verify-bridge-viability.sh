#!/bin/bash
# Does a bridge of two dataplane ports forward at all on this image?
#
# This is the substrate Private VLAN would sit on, and it is worth establishing
# before writing any of it. The assessment's own lesson from nhrpd is that a
# feature can look present at every layer above the forwarding path and still
# not work: the CLI accepts it, the daemon runs, and nothing gets through.
#
# Private VLAN is enforcement on top of bridging -- the port roles decide which
# member ports may reach which. If bridging between two dataplane ports does
# not forward here, the roles have nothing to restrict and no way to be tested.
#
# The topology gives R2 two dataplane ports facing different routers, so
# bridging them puts R1 and R3 on one L2 segment through R2:
#
#   R1 dp0s9 10.50.50.1/24 ----- dp0s3 [ R2  br0 ] dp0s8 ----- dp0s8 10.50.50.3/24 R3
#
# TOPO=ipsec wiring: R1.dp0s9 <-> R2.dp0s3, R2.dp0s8 <-> R3.dp0s8.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-bridge-viability.log}
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
	        vcli -s \$SID -c commit 2>&1 | grep -viE 'sssd|configuration db|grub|boot-loader|crash dump|^\s*\$' | tail -3"
}

ping_r1_r3() {
	S $R1 "ping -c 4 -W 2 10.50.50.3 2>&1 | grep -oE '[0-9]+ received'" | tail -1
}

echo "===== 1. Hosts on one segment, bridged through R2 ====="
cli $R1 "set interfaces dataplane dp0s9 address 10.50.50.1/24" | sed 's/^/  R1: /'
cli $R3 "set interfaces dataplane dp0s8 address 10.50.50.3/24" | sed 's/^/  R3: /'
cli $R2 "set interfaces bridge br0" \
        "set interfaces dataplane dp0s3 bridge-group bridge br0" \
        "set interfaces dataplane dp0s8 bridge-group bridge br0" | sed 's/^/  R2: /'
sleep 10

echo; echo "===== 2. Does the bridge exist in the dataplane? ====="
S $R2 'sudo /opt/vyatta/bin/vplsh -l -c "ifconfig br0" 2>&1 | head -c 200; echo' | tail -2 | sed 's/^/  /'
S $R2 'printf "  kernel br0: %s\n" "$(ip -br link show br0 2>/dev/null || echo absent)"' | tail -1

echo; echo "===== 3. Are both ports members? ====="
S $R2 'echo "  kernel members: $(ls /sys/class/net/br0/brif 2>/dev/null | tr "\n" " ")"
       echo "  dataplane sees bridge on:"
       sudo /opt/vyatta/bin/vplsh -l -c ifconfig 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
for i in d.get(\"interfaces\", []):
    if i.get(\"bridge\"): print(\"    %s -> %s\" % (i.get(\"name\"), i[\"bridge\"]))
" 2>/dev/null' | tail -5

echo; echo "===== 4. Does it forward? ====="
printf '  ping R1 -> R3 through the bridge: %s of 4\n' "$(ping_r1_r3)"

echo; echo "===== 5. Did the bridge learn both addresses? ====="
S $R2 'sudo /opt/vyatta/bin/vplsh -l -c "bridge br0 macs" 2>&1 | head -c 500; echo' | tail -3 | sed 's/^/  /'

echo; echo "===== 6. Verdict ====="
got=$(ping_r1_r3 | tr -dc '0-9')
if [ -n "$got" ] && [ "$got" -ge 3 ]; then
	echo "  VIABLE: two dataplane ports in a bridge forward between routers."
	echo "  Private VLAN has something to restrict, and a way to be tested:"
	echo "    both ports isolated   -> this ping must fail"
	echo "    one port promiscuous  -> this ping must pass"
else
	echo "  NOT VIABLE: the bridge does not forward, so port roles would have"
	echo "  nothing to act on. Fix bridging first; writing Private VLAN against"
	echo "  this would produce configuration that commits and does nothing."
fi

echo; echo "===== 7. Clean up ====="
# Leave the routers as they were found -- leftover state from a verification
# has twice been mistaken for a regression in this project.
cli $R2 "delete interfaces dataplane dp0s3 bridge-group" \
        "delete interfaces dataplane dp0s8 bridge-group" \
        "delete interfaces bridge br0" > /dev/null
cli $R1 "delete interfaces dataplane dp0s9 address 10.50.50.1/24" > /dev/null
cli $R3 "delete interfaces dataplane dp0s8 address 10.50.50.3/24" > /dev/null
sleep 6
S $R2 'printf "  br0 gone: %s\n" "$(ip link show br0 >/dev/null 2>&1 && echo no || echo yes)"' | tail -1
