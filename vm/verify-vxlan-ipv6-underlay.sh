#!/bin/bash
# Does VXLAN carry a bridge domain over an IPv6 underlay?
#
# The datapath always could: vxlan_output() and vxlan_send_packet() handle
# AF_INET6 and the table has vxlrt_dst_v6. What did not was the netlink entry
# point, which took a four-byte NDA_DST or nothing, so no MAC a control plane
# programmed over an IPv6 fabric was ever installed. That is fixed; this is
# whether it works.
#
# Two things are measured and they are not the same claim:
#
#   the tunnel forwards over IPv6       ordinary flooding and learning, which
#                                       needed no fix and might still have
#                                       been broken for other reasons
#   a programmed MAC forwards           the netlink path, which is the fix
#
# The second is arranged the way the IPv4 version was: the tunnel's own
# remote-ip is pointed at an address nothing answers, so flooding is a dead
# end, and the only entry that can carry the traffic is the one injected with
# an IPv6 dst. Without that, a working ping says only that flooding worked.
#
#   R1  VTEP 2001:db8:60::1/64 on dp0s9, br0 10.61.61.1/24, tun0 (VNI 100)
#   R2  VTEP 2001:db8:60::2/64 on dp0s3, br0 10.61.61.2/24, tun0 + dp0s8
#   R3  host 10.61.61.3/24 on dp0s8
#
# The overlay stays IPv4 on purpose. Changing both layers at once would leave
# a failure ambiguous between the underlay being new and the overlay being
# new, and the overlay is not what changed.
#
# TOPO=ipsec wiring: R1.dp0s9 <-> R2.dp0s3, R2.dp0s8 <-> R3.dp0s8.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-vxlan-ipv6-underlay.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.155
R2=192.168.203.156
R3=192.168.203.157
V6_A=2001:db8:60::1
V6_B=2001:db8:60::2
V6_DEAD=2001:db8:60::99      # nothing answers here
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

reach() {
	S $R1 "sudo ip neigh replace 10.61.61.3 lladdr $MAC3 dev br0 2>/dev/null
	       ping -c 3 -W 2 10.61.61.3 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | tr -dc '0-9'
}

cleanup() {
	echo; echo "===== Clean up ====="
	cli $R1 "delete interfaces tunnel tun0" "delete interfaces bridge br0" \
	        "delete interfaces dataplane dp0s9 address $V6_A/64" > /dev/null
	cli $R2 "delete interfaces dataplane dp0s8 bridge-group" \
	        "delete interfaces tunnel tun0" "delete interfaces bridge br0" \
	        "delete interfaces dataplane dp0s3 address $V6_B/64" > /dev/null
	cli $R3 "delete interfaces dataplane dp0s8 address 10.61.61.3/24" > /dev/null
	sleep 6
	for h in $R1 $R2; do
		S "$h" 'printf "  tun0 %s  br0 %s\n" \
		          "$(ip link show tun0 >/dev/null 2>&1 && echo LEFT || echo gone)" \
		          "$(ip link show br0 >/dev/null 2>&1 && echo LEFT || echo gone)"' | tail -1
	done
}

echo "===== 1. An IPv6 underlay, an IPv4 bridge domain over it ====="
cli $R1 "set interfaces dataplane dp0s9 address $V6_A/64" \
        "set interfaces tunnel tun0 encapsulation vxlan" \
        "set interfaces tunnel tun0 vxlan-id 100" \
        "set interfaces tunnel tun0 local-ip $V6_A" \
        "set interfaces tunnel tun0 remote-ip $V6_B" \
        "set interfaces bridge br0" \
        "set interfaces bridge br0 address 10.61.61.1/24" \
        "set interfaces tunnel tun0 bridge-group bridge br0" | tail -2
cli $R2 "set interfaces dataplane dp0s3 address $V6_B/64" \
        "set interfaces tunnel tun0 encapsulation vxlan" \
        "set interfaces tunnel tun0 vxlan-id 100" \
        "set interfaces tunnel tun0 local-ip $V6_B" \
        "set interfaces tunnel tun0 remote-ip $V6_A" \
        "set interfaces bridge br0" \
        "set interfaces bridge br0 address 10.61.61.2/24" \
        "set interfaces tunnel tun0 bridge-group bridge br0" \
        "set interfaces dataplane dp0s8 bridge-group bridge br0" | tail -2
cli $R3 "set interfaces dataplane dp0s8 address 10.61.61.3/24" | tail -2
sleep 16
MAC3=$(S $R3 "cat /sys/class/net/dp0s8/address" | tail -1)
echo "  R3 dp0s8 MAC: $MAC3"

echo
echo "===== 2. The underlay itself ====="
# If this does not work nothing below means anything, and the cause would be
# the topology rather than VXLAN.
r=$(S $R1 "ping6 -c 3 -W 2 $V6_B 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | tr -dc '0-9')
if [ "${r:-0}" -ge 2 ]; then ok "R1 reaches R2 over IPv6: $r of 3"
else bad "R1 reaches R2 over IPv6" "got $r of 3 -- the underlay is not up"; fi
echo "  R1's tunnel as the dataplane sees it:"
S $R1 "sudo /opt/vyatta/bin/vplsh -l -c 'ifconfig tun0' 2>/dev/null | python3 -c \"
import sys, json
d = json.load(sys.stdin)
for i in d.get('interfaces', []):
    v = i.get('vxlan') or {}
    print('    %s  src=%s  dest=%s  vni=%s' % (i.get('name'), v.get('src'),
          v.get('dest') or v.get('group'), v.get('vni')))
\" 2>/dev/null" | tail -2

if [ "$fail" -ne 0 ]; then cleanup; exit "$fail"; fi

echo
echo "===== 3. The bridge domain forwards over it ====="
# Flooding and learning, which needed no fix but could still have been broken.
got=$(reach)
if [ "${got:-0}" -ge 2 ]; then ok "R1 reaches R3 across the IPv6 tunnel: $got of 3"
else bad "R1 reaches R3 across the IPv6 tunnel" "got $got of 3"; fi
e=$(entry); echo "    R1's entry for R3: $e"
case "$e" in
  *"$V6_B"*) ok "the learned entry carries an IPv6 VTEP" ;;
  absent)    bad "the learned entry carries an IPv6 VTEP" "absent" ;;
  *)         bad "the learned entry carries an IPv6 VTEP" "$e" ;;
esac

echo
echo "===== 4. Kill the flood path ====="
# From here a working ping can only be the programmed entry. Without this the
# tunnel's own remote-ip would carry it and the result would say nothing about
# the netlink path.
cli $R1 "set interfaces tunnel tun0 remote-ip $V6_DEAD" | tail -2
S $R1 "sudo /opt/vyatta/bin/vplsh -l -c 'vxlan macs clear tun0' >/dev/null 2>&1" > /dev/null
sleep 8
e=$(entry); echo "    R1's entry for R3: $e"
got=$(reach)
if [ "${got:-9}" -eq 0 ]; then ok "with the flood path dead, R3 is unreachable: $got of 3"
else bad "with the flood path dead, R3 is unreachable" \
         "got $got of 3 -- something else is carrying this and step 6 would prove nothing"; fi

echo
echo "===== 5. Program the MAC with an IPv6 VTEP ====="
# This is the path that was closed: a sixteen-byte NDA_DST.
S $R1 "sudo bridge fdb replace $MAC3 dev tun0 dst $V6_B extern_learn 2>&1; echo done" > /dev/null
sleep 6
e=$(entry); echo "    R1's entry for R3: $e"
case "$e" in
  control-plane*"$V6_B"*True) ok "the entry is control-plane, IPv6, and forwardable" ;;
  absent) bad "the entry is control-plane, IPv6, and forwardable" \
              "absent -- the sixteen-byte NDA_DST was refused, which is the old behaviour" ;;
  *)      bad "the entry is control-plane, IPv6, and forwardable" "$e" ;;
esac

echo
echo "===== 6. And it forwards ====="
got=$(reach)
if [ "${got:-0}" -ge 2 ]; then ok "traffic reaches R3 through the programmed IPv6 VTEP: $got of 3"
else bad "traffic reaches R3 through the programmed IPv6 VTEP" "got $got of 3"; fi

echo
echo "===== 7. Nothing was counted as unusable ====="
bad_dst=$(S $R1 "sudo /opt/vyatta/bin/vplsh -l -c 'vxlan stats show' 2>/dev/null \
	  | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"vxlan_stats\"][\"NeighDroppedBadDst\"])' 2>/dev/null" \
	  | tail -1 | grep -E '^[0-9]+$' || echo "")
if [ -z "$bad_dst" ]; then
	bad "NeighDroppedBadDst is readable" "did not parse -- cannot say whether anything was dropped"
elif [ "$bad_dst" -eq 0 ]; then
	ok "NeighDroppedBadDst is 0, so no NDA_DST was refused"
else
	bad "NeighDroppedBadDst is 0, so no NDA_DST was refused" "it is $bad_dst"
fi

echo
echo "===== 8. Result ====="
printf '  %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
	echo "  VXLAN WORKS OVER AN IPv6 UNDERLAY, both ways it can: the bridge"
	echo "  domain forwards over an IPv6 tunnel, and a MAC programmed with a"
	echo "  sixteen-byte NDA_DST is installed and used -- which is the entry"
	echo "  point that used to refuse it."
else
	echo "  Something above did not hold. If step 5 reports the entry absent,"
	echo "  the sixteen-byte NDA_DST is still being refused and step 7 should"
	echo "  show NeighDroppedBadDst rising to match."
fi

cleanup
exit "$fail"
