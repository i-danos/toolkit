#!/bin/bash
# Does a MAC that moves to another VTEP follow?
#
# vxlan_newneigh()'s update branch used to take the new NUD state and leave
# vxlrt_dst alone:
#
#     vrt->vxlrt_flags = ndmstate_to_flags(state);   /* and nothing else */
#
# A MAC move is signalled as the same MAC arriving with a different NDA_DST,
# so the entry kept pointing at the VTEP the host had left and traffic went on
# being encapsulated there. The branch refreshes the address now. Nothing had
# measured it.
#
# The move is injected the way FRR programs one: "bridge fdb add <mac> dev
# tunN dst <vtep>" with a different dst. That is the same netlink message
# zebra sends for a type-2 route with a new next hop, so it exercises the
# code under test without needing a host to physically migrate -- which three
# routers cannot arrange anyway.
#
# Both VTEPs are R2, on two addresses of the same port. From R1's dataplane
# that is a genuine VTEP change, and both are reachable, so forwarding can be
# measured before and after rather than only the table.
#
#   R1  VTEP 10.60.60.1   br0 10.61.61.1/24, tun0 (VNI 100)
#   R2  VTEPs 10.60.60.2 and 10.60.60.22 on dp0s3, br0 + dp0s8
#   R3  host 10.61.61.3/24 on dp0s8
#
# TOPO=ipsec wiring: R1.dp0s9 <-> R2.dp0s3, R2.dp0s8 <-> R3.dp0s8.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-vxlan-mac-move.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.155
R2=192.168.203.156
R3=192.168.203.157
VTEP_A=10.60.60.2
VTEP_B=10.60.60.22
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

# "<origin> <type> <remote_ip> <forwards>" for R3's MAC in R1's table.
entry() {
	S $R1 "sudo /opt/vyatta/bin/vplsh -l -c 'vxlan macs show' 2>/dev/null" | python3 -c "
import sys, json
want = '$MAC3'
try:
    d = json.load(sys.stdin)
except Exception:
    print('unreadable'); sys.exit()
for t in d.get('mac_table', []):
    for e in t.get('entries', []):
        if e.get('mac') == want:
            print('%s %s %s %s' % (e.get('origin'), e.get('type'),
                                   e.get('remote_ip') or '-', e.get('forwards')))
            sys.exit()
print('absent')
" 2>/dev/null | tail -1
}

# Program the MAC at one VTEP, exactly as FRR would -- extern_learn included.
# Without it the entry is classified "configured" rather than "control-plane",
# which is the dump being right and the test being less like the real thing:
# a MAC move in a fabric always arrives carrying NTF_EXT_LEARNED, and that
# flag now decides whether the data path may overwrite the entry and whether
# ageing may take it. Refreshing vxlrt_dst is the same line either way, so the
# first version of this test was weaker rather than wrong.
program_at() {
	S $R1 "sudo bridge fdb replace $MAC3 dev tun0 dst $1 extern_learn 2>&1; echo done" > /dev/null
	sleep 5
}

reach() {
	S $R1 "sudo ip neigh replace 10.61.61.3 lladdr $MAC3 dev br0 2>/dev/null
	       ping -c 3 -W 2 10.61.61.3 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | tr -dc '0-9'
}

cleanup() {
	echo; echo "===== Clean up ====="
	cli $R1 "delete interfaces tunnel tun0" "delete interfaces bridge br0" \
	        "delete interfaces dataplane dp0s9 address 10.60.60.1/24" > /dev/null
	cli $R2 "delete interfaces dataplane dp0s8 bridge-group" \
	        "delete interfaces tunnel tun0" "delete interfaces bridge br0" \
	        "delete interfaces dataplane dp0s3 address $VTEP_A/24" \
	        "delete interfaces dataplane dp0s3 address $VTEP_B/24" > /dev/null
	cli $R3 "delete interfaces dataplane dp0s8 address 10.61.61.3/24" > /dev/null
	sleep 6
	for h in $R1 $R2; do
		S "$h" 'printf "  tun0 %s  br0 %s\n" \
		          "$(ip link show tun0 >/dev/null 2>&1 && echo LEFT || echo gone)" \
		          "$(ip link show br0 >/dev/null 2>&1 && echo LEFT || echo gone)"' | tail -1
	done
}

echo "===== 1. One bridge domain, two VTEPs on the far side ====="
cli $R1 "set interfaces dataplane dp0s9 address 10.60.60.1/24" \
        "set interfaces tunnel tun0 encapsulation vxlan" \
        "set interfaces tunnel tun0 vxlan-id 100" \
        "set interfaces tunnel tun0 local-ip 10.60.60.1" \
        "set interfaces tunnel tun0 remote-ip $VTEP_A" \
        "set interfaces bridge br0" \
        "set interfaces bridge br0 address 10.61.61.1/24" \
        "set interfaces tunnel tun0 bridge-group bridge br0" | tail -2
cli $R2 "set interfaces dataplane dp0s3 address $VTEP_A/24" \
        "set interfaces dataplane dp0s3 address $VTEP_B/24" \
        "set interfaces tunnel tun0 encapsulation vxlan" \
        "set interfaces tunnel tun0 vxlan-id 100" \
        "set interfaces tunnel tun0 local-ip $VTEP_A" \
        "set interfaces tunnel tun0 remote-ip 10.60.60.1" \
        "set interfaces bridge br0" \
        "set interfaces bridge br0 address 10.61.61.2/24" \
        "set interfaces tunnel tun0 bridge-group bridge br0" \
        "set interfaces dataplane dp0s8 bridge-group bridge br0" | tail -2
cli $R3 "set interfaces dataplane dp0s8 address 10.61.61.3/24" | tail -2
sleep 14
MAC3=$(S $R3 "cat /sys/class/net/dp0s8/address" | tail -1)
echo "  R3 dp0s8 MAC: $MAC3"

# Both VTEP addresses must answer, or "moved and still reachable" cannot be
# told from "moved to somewhere that happens to be dead".
for v in $VTEP_A $VTEP_B; do
	r=$(S $R1 "ping -c 2 -W 2 $v 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | tr -dc '0-9')
	if [ "${r:-0}" -ge 1 ]; then ok "VTEP $v answers"; else bad "VTEP $v answers" "got $r"; fi
done

echo
echo "===== 2. Program the MAC at $VTEP_A ====="
program_at $VTEP_A
e=$(entry); echo "    $e"
case "$e" in
  *"$VTEP_A"*) ok "the table points at $VTEP_A" ;;
  *)           bad "the table points at $VTEP_A" "$e" ;;
esac
case "$e" in
  control-plane*) ok "and it is recorded as control-plane, as a fabric move would be" ;;
  *)              bad "and it is recorded as control-plane, as a fabric move would be" \
                      "$e -- extern_learn did not reach the dataplane" ;;
esac
got=$(reach)
if [ "${got:-0}" -ge 2 ]; then ok "traffic reaches R3 through $VTEP_A: $got of 3"
else bad "traffic reaches R3 through $VTEP_A" "got $got of 3"; fi

echo
echo "===== 3. The same MAC arrives from $VTEP_B ====="
# This is the move. Before the fix the entry kept $VTEP_A and traffic
# followed it there.
program_at $VTEP_B
e=$(entry); echo "    $e"
case "$e" in
  *"$VTEP_B"*) ok "the table followed the move to $VTEP_B" ;;
  *"$VTEP_A"*) bad "the table followed the move to $VTEP_B" \
                   "still $VTEP_A -- the update branch is not taking the new address" ;;
  *)           bad "the table followed the move to $VTEP_B" "$e" ;;
esac

echo
echo "===== 4. And forwarding followed it ====="
# The table is not the product. An entry that reads correctly and forwards to
# the old VTEP is the defect this is about.
got=$(reach)
if [ "${got:-0}" -ge 2 ]; then ok "traffic still reaches R3 after the move: $got of 3"
else bad "traffic still reaches R3 after the move" "got $got of 3"; fi

echo
echo "===== 5. And back again ====="
# One move could be the entry being recreated rather than updated. Moving it
# back exercises the update branch in the other direction.
program_at $VTEP_A
e=$(entry); echo "    $e"
case "$e" in
  *"$VTEP_A"*) ok "the table followed the move back to $VTEP_A" ;;
  *)           bad "the table followed the move back to $VTEP_A" "$e" ;;
esac

echo
echo "===== 6. Result ====="
printf '  %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
	echo "  A MOVED MAC FOLLOWS. The entry takes the new VTEP in both"
	echo "  directions and traffic goes where the entry says."
else
	echo "  Something above did not hold. If step 3 reports the table still"
	echo "  pointing at $VTEP_A, vxlan_newneigh()'s update branch is not"
	echo "  assigning vxlrt_dst -- which is the defect this test exists for."
fi

cleanup
exit "$fail"
