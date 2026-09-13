#!/bin/bash
# Does a tunnel's configured local-ip become the source of its packets?
#
# set_vxlan_params() stored s_addr = 0 unconditionally and never read
# IFLA_VXLAN_LOCAL, which the kernel sends whenever a local-ip is configured
# -- "ip -d link show tun4" prints it as "local 10.60.60.1". Zero means
# "select the source from the route", and vxlan_select_ipv4_src() has always
# had the other branch ready:
#
#     if (vnode->s_addr == 0) { ... ip_select_source(...) }
#     else                    { sip->address.ip_v4.s_addr = vnode->s_addr; }
#
# so the configuration was carried all the way to the dataplane and discarded
# one assignment before the code that wanted it.
#
# This began as a display complaint -- "ifconfig tunN" reporting source=None
# on a tunnel that had one. It is not a display defect. An operator who names
# a source address and gets whatever the route picks has a tunnel that works
# until the far end filters on it, or until a second address on the egress
# interface changes what selection returns.
#
# Measured where it shows: the source address of the encapsulated packets, on
# the far end, not in the dump. The dump agreeing is checked too, because that
# is what someone debugging will look at first.
#
#   R1  dp0s9 10.60.60.1 and 10.60.60.11, tun4 local-ip 10.60.60.11
#   R2  dp0s3 10.60.60.2, tun4 remote-ip 10.60.60.1
#
# The local-ip is deliberately NOT the address routing would choose. R1's
# route to 10.60.60.2 leaves by dp0s9, whose primary is .1, so an
# unconfigured or ignored local-ip gives .1 and a working one gives .11.
# Picking .1 for both would make the test pass either way.
#
# TOPO=ipsec wiring: R1.dp0s9 <-> R2.dp0s3.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-vxlan-local-ip.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.155
R2=192.168.203.156
PRIMARY=10.60.60.1
LOCAL=10.60.60.11
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

dp_source() {
	S $R1 "sudo /opt/vyatta/bin/vplsh -l -c 'ifconfig tun4' 2>/dev/null" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print('unreadable'); sys.exit()
for i in d.get('interfaces', []):
    v = i.get('vxlan') or {}
    if i.get('name') == 'tun4':
        print(v.get('source') or 'none')
        sys.exit()
print('no-tun4')
" 2>/dev/null | tail -1
}

cleanup() {
	echo; echo "===== Clean up ====="
	cli $R1 "delete interfaces tunnel tun4" "delete interfaces bridge br4" \
	        "delete interfaces dataplane dp0s9 address $PRIMARY/24" \
	        "delete interfaces dataplane dp0s9 address $LOCAL/24" > /dev/null
	cli $R2 "delete interfaces tunnel tun4" "delete interfaces bridge br4" \
	        "delete interfaces dataplane dp0s3 address 10.60.60.2/24" > /dev/null
	sleep 5
	S $R1 'printf "  tun4 %s  br4 %s\n" \
	        "$(ip link show tun4 >/dev/null 2>&1 && echo LEFT || echo gone)" \
	        "$(ip link show br4 >/dev/null 2>&1 && echo LEFT || echo gone)"' | tail -1
}

echo "===== 1. A local-ip that routing would not choose ====="
cli $R1 "set interfaces dataplane dp0s9 address $PRIMARY/24" \
        "set interfaces dataplane dp0s9 address $LOCAL/24" \
        "set interfaces tunnel tun4 encapsulation vxlan" \
        "set interfaces tunnel tun4 vxlan-id 44" \
        "set interfaces tunnel tun4 local-ip $LOCAL" \
        "set interfaces tunnel tun4 remote-ip 10.60.60.2" \
        "set interfaces bridge br4" \
        "set interfaces bridge br4 address 10.44.44.1/24" \
        "set interfaces tunnel tun4 bridge-group bridge br4" | tail -2
cli $R2 "set interfaces dataplane dp0s3 address 10.60.60.2/24" \
        "set interfaces tunnel tun4 encapsulation vxlan" \
        "set interfaces tunnel tun4 vxlan-id 44" \
        "set interfaces tunnel tun4 local-ip 10.60.60.2" \
        "set interfaces tunnel tun4 remote-ip $LOCAL" \
        "set interfaces bridge br4" \
        "set interfaces bridge br4 address 10.44.44.2/24" \
        "set interfaces tunnel tun4 bridge-group bridge br4" | tail -2
sleep 14

echo "  what the kernel was told:"
S $R1 "ip -d link show tun4 2>/dev/null | grep -oE 'vxlan id [0-9]+ remote [0-9.]+ local [0-9.]+'" | tail -1 | sed 's/^/    /'

echo
echo "===== 2. The dataplane kept it ====="
src=$(dp_source)
echo "    ifconfig tun4 source: $src"
if [ "$src" = "$LOCAL" ]; then
	ok "the dump reports the configured local-ip"
elif [ "$src" = "none" ]; then
	bad "the dump reports the configured local-ip" \
	    "source is absent -- IFLA_VXLAN_LOCAL was not stored"
else
	bad "the dump reports the configured local-ip" "source is $src, expected $LOCAL"
fi

echo
echo "===== 3. The packets carry it ====="
# The dump is not the product. Capture on R2's underlay port and read the
# outer source of the VXLAN packets, which is what a far end filters on.
S $R2 "sudo timeout 25 tcpdump -n -i dp0s3 -c 8 'udp port 4789' -w /tmp/v.pcap >/dev/null 2>&1 &" > /dev/null
sleep 3
S $R1 "ping -c 5 -W 2 10.44.44.2 >/dev/null 2>&1" > /dev/null
sleep 24
outer=$(S $R2 "sudo tcpdump -n -r /tmp/v.pcap 2>/dev/null | grep -oE '^[0-9:.]+ IP [0-9.]+' | awk '{print \$3}' | sort -u | head -4")
printf '%s\n' "$outer" | sed 's/^/    outer source seen: /'
if printf '%s' "$outer" | grep -q "^$LOCAL\.\|^$LOCAL$"; then
	ok "the encapsulated packets leave with $LOCAL"
elif printf '%s' "$outer" | grep -q "$PRIMARY"; then
	bad "the encapsulated packets leave with $LOCAL" \
	    "they carry $PRIMARY -- the route's choice, so local-ip is still ignored"
else
	bad "the encapsulated packets leave with $LOCAL" "saw: $outer"
fi

echo
echo "===== 4. And it still forwards ====="
# A source address the far end does not expect is a way to break a tunnel
# while every table looks right.
got=$(S $R1 "ping -c 3 -W 2 10.44.44.2 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | tr -dc '0-9')
if [ "${got:-0}" -ge 2 ]; then ok "the tunnel still carries traffic: $got of 3"
else bad "the tunnel still carries traffic" "got $got of 3"; fi

echo
echo "===== 5. Result ====="
printf '  %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
	echo "  A CONFIGURED local-ip IS USED. It reaches the dataplane, it is"
	echo "  what the dump reports, and it is the outer source address on the"
	echo "  wire -- which is the only one of the three the far end sees."
else
	echo "  Something above did not hold. If step 3 shows $PRIMARY, the"
	echo "  address is being chosen by ip_select_source() because s_addr is"
	echo "  still zero, whatever the dump says."
fi

cleanup
exit "$fail"
