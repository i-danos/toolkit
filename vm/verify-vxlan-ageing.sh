#!/bin/bash
# Do control-plane MACs survive the ageing timer, and do learned ones still go?
#
# vxlan_rtexpired() ages anything IFBAF_DYNAMIC that has not been used for
# VXLAN_RTABLE_EXPIRE ticks -- thirty minutes. FRR's remote MACs arrive with
# an NUD state that maps to IFBAF_DYNAMIC, so they were included: a remote
# host that goes quiet for half an hour stopped being reachable, and FRR,
# whose own state had not changed, would never have reprogrammed it. Entries
# carrying NTF_EXT_LEARNED are now left to their owner.
#
# This takes thirty-five minutes because the interval is thirty and there is
# no way to shorten it without a different build. Run it when the topology is
# free.
#
# The run carries its own control. Two entries are set up for the same VNI:
#
#   a control-plane entry   programmed over netlink, must survive
#   a data-path entry       learned from a frame, must age out
#
# If both survive, the timer is not running at all and the first result means
# nothing -- which is the failure this design exists to catch. A test that
# only checked the control-plane entry would pass just as well on a dataplane
# whose ageing was broken outright.
#
# No traffic may cross the tunnel during the wait, or the data-path entry is
# marked used and the control is lost. The script sends none; anything else
# using these routers will invalidate it.
#
#   R1  VTEP 10.60.60.1   br0 10.61.61.1/24, tun0 (VNI 100)
#   R2  VTEP 10.60.60.2   br0 10.61.61.2/24, tun0 + dp0s8
#   R3  host 10.61.61.3/24 on dp0s8
#
# TOPO=ipsec wiring: R1.dp0s9 <-> R2.dp0s3, R2.dp0s8 <-> R3.dp0s8.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-vxlan-ageing.log}
WAIT=${WAIT:-2100}          # 35 minutes; the timer expires at 30
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.155
R2=192.168.203.156
R3=192.168.203.157
CP_MAC=02:00:00:00:0c:01    # programmed over netlink, never seen on the wire
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

# "<origin> <type>" for one MAC in R1's table, or "absent".
entry() {
	S $R1 "sudo /opt/vyatta/bin/vplsh -l -c 'vxlan macs show' 2>/dev/null" | python3 -c "
import sys, json
want = '$1'
try:
    d = json.load(sys.stdin)
except Exception:
    print('unreadable'); sys.exit()
for t in d.get('mac_table', []):
    for e in t.get('entries', []):
        if e.get('mac') == want:
            print('%s %s' % (e.get('origin'), e.get('type')))
            sys.exit()
print('absent')
" 2>/dev/null | tail -1
}

cleanup() {
	echo; echo "===== Clean up ====="
	cli $R1 "delete interfaces tunnel tun0" "delete interfaces bridge br0" \
	        "delete interfaces dataplane dp0s9 address 10.60.60.1/24" > /dev/null
	cli $R2 "delete interfaces dataplane dp0s8 bridge-group" \
	        "delete interfaces tunnel tun0" "delete interfaces bridge br0" \
	        "delete interfaces dataplane dp0s3 address 10.60.60.2/24" > /dev/null
	cli $R3 "delete interfaces dataplane dp0s8 address 10.61.61.3/24" > /dev/null
	sleep 6
	for h in $R1 $R2; do
		S "$h" 'printf "  tun0 %s  br0 %s\n" \
		          "$(ip link show tun0 >/dev/null 2>&1 && echo LEFT || echo gone)" \
		          "$(ip link show br0 >/dev/null 2>&1 && echo LEFT || echo gone)"' | tail -1
	done
}

echo "===== 1. Topology ====="
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
sleep 14
MAC3=$(S $R3 "cat /sys/class/net/dp0s8/address" | tail -1)
echo "  R3 dp0s8 MAC: $MAC3  (will be learned from traffic)"
echo "  control-plane MAC: $CP_MAC  (programmed, never on the wire)"

echo
echo "===== 2. Two entries, one of each kind ====="
# extern_learn is what makes it a control-plane entry; without it this is
# just a static entry and the ageing guard does not apply.
S $R1 "sudo bridge fdb replace $CP_MAC dev tun0 dst 10.60.60.2 extern_learn 2>&1; echo done" > /dev/null
# And one the data path learns, by pulling a frame across the tunnel.
S $R1 "sudo ip neigh replace 10.61.61.3 lladdr $MAC3 dev br0 2>/dev/null
       ping -c 3 -W 2 10.61.61.3 >/dev/null 2>&1; echo done" > /dev/null
sleep 6

cp_e=$(entry "$CP_MAC")
dp_e=$(entry "$MAC3")
echo "    control-plane entry: $cp_e"
echo "    data-path entry:     $dp_e"
case "$cp_e" in
  control-plane*) ok "the programmed MAC is recorded as control-plane" ;;
  *)              bad "the programmed MAC is recorded as control-plane" "$cp_e" ;;
esac
case "$dp_e" in
  data-path*) ok "the learned MAC is recorded as data-path" ;;
  absent)     bad "the learned MAC is recorded as data-path" \
                  "absent -- no frame reached R1 over the tunnel, so there is no control" ;;
  *)          bad "the learned MAC is recorded as data-path" "$dp_e" ;;
esac

if [ "$fail" -ne 0 ]; then
	echo
	echo "  Not waiting $WAIT seconds for a run that cannot conclude."
	cleanup
	exit "$fail"
fi

echo
echo "===== 3. Silence for $WAIT seconds ====="
echo "    started $(date -u '+%H:%M:%SZ'), the timer expires at 30 minutes"
echo "    nothing is sent from here; other traffic on these routers will"
echo "    refresh the data-path entry and invalidate the control."
sleep "$WAIT"
echo "    finished $(date -u '+%H:%M:%SZ')"

echo
echo "===== 4. What is left ====="
cp_e=$(entry "$CP_MAC")
dp_e=$(entry "$MAC3")
echo "    control-plane entry: $cp_e"
echo "    data-path entry:     $dp_e"

case "$cp_e" in
  control-plane*) ok "the control-plane entry survived, as its owner decides its lifetime" ;;
  absent)         bad "the control-plane entry survived" \
                      "it was aged out -- the IFBAF_EXT_LEARNED guard is not holding" ;;
  *)              bad "the control-plane entry survived" "$cp_e" ;;
esac

case "$dp_e" in
  absent) ok "the data-path entry aged out, so the timer really ran" ;;
  *)      bad "the data-path entry aged out, so the timer really ran" \
              "still $dp_e -- either something kept using it or ageing is not running at all," \
              "and in that case the result above says nothing" ;;
esac

echo
echo "===== 5. Result ====="
printf '  %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
	echo "  AGEING LEAVES CONTROL-PLANE ENTRIES ALONE. The learned entry went"
	echo "  in the same interval, which is what makes the first half mean"
	echo "  something."
fi

cleanup
exit "$fail"
