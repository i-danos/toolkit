#!/bin/bash
# Does the dead end NHRP registration falls into get counted, instead of being
# silent?
#
# gre_tunnel_encap() punts to the kernel when the mGRE peer lookup misses. For a
# packet off the forwarding path that is correct -- it is how NHRP resolution
# starts. For a packet the kernel itself handed over it is a bounce:
# ip_local_deliver() returns it to the sender and it dies there, moving no
# counter on either side. NHRP registration ends up there every time.
#
# NHRP registration is the generator. nhrpd retries on an exponential backoff
# and each attempt is one such packet, so tx_errors on the tunnel has to climb
# while registration is failing. That climb is the whole point of the change --
# it does not fix NHRP, it makes NHRP's failure visible.
#
# An earlier version of this script tested a different branch, on a diagnosis
# that turned out to be wrong: it assumed nxt_ip was NULL and the packet was
# encapsulated to 0.0.0.0. tx_errors never moved, because that branch is never
# taken. Hence the two things this version does that the first did not -- prove
# the generator is running, and read .spathintf in both directions.
#
# See toolkit/docs/DEFECT-nhrp-mgre-slowpath.md.
#
#   R1  spoke  dp0s3 201.1.1.1, tun0 172.30.0.2/32
#   R2  hub    dp0s3 201.1.1.2, tun0 172.30.0.1/32
#
# TOPO=bgp wiring: R1.dp0s3 <-> R2.dp0s3 on 201.1.1.0/24.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-mgre-no-peer-drop.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
SPOKE=192.168.203.231
HUB=192.168.203.232

exec > "$OUT" 2>&1
S() { docker exec danos-robot timeout 200 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$1" "$2" 2>&1; }

cli() {
	local h=$1; shift
	local c=""
	for x in "$@"; do c="$c vcli -s \$SID -c \"$x\" 2>&1;"; done
	S "$h" "SID=\$\$; eval \"\$(cli-shell-api getSessionEnv \$SID)\"; cli-shell-api setupSession; $c
	        vcli -s \$SID -c commit 2>&1 | grep -viE 'sssd|configuration db|grub|boot-loader|crash dump|^\s*\$' | tail -2"
}

# tx_errors on the tunnel, which is if_incr_oerror(). Printed as a bare integer
# so the caller can do arithmetic on it; empty if the interface is not there.
tun_tx_errors() {
	S "$1" "sudo /opt/vyatta/bin/vplsh -l -c 'ifconfig tun0' 2>/dev/null | python3 -c \"
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit()
for i in d.get('interfaces', []):
    print(i.get('statistics', {}).get('tx_errors', ''))
\"" | tail -1 | tr -dc '0-9'
}

tun_dest() {
	S "$1" "sudo /opt/vyatta/bin/vplsh -l -c 'ifconfig tun0' 2>/dev/null | python3 -c \"
import sys, json
d = json.load(sys.stdin)
for i in d.get('interfaces', []):
    g = i.get('gre')
    if g: print(g.get('dest'))
\"" | tail -1
}

echo "===== 1. Enable nhrpd, which the shipped daemons file leaves out ====="
for h in $SPOKE $HUB; do
	S "$h" 'sudo sh -c "grep -q \"^nhrpd=\" /etc/frr/daemons || echo nhrpd=yes >> /etc/frr/daemons"
	        sudo systemctl restart frr >/dev/null 2>&1
	        sleep 8
	        printf "  %s nhrpd=%s zebra=%s\n" "$(hostname)" "$(pgrep -xc nhrpd)" "$(pgrep -xc zebra)"' | tail -1
done

echo; echo "===== 2. Multipoint tunnels, host prefixes ====="
cli $HUB   "set interfaces dataplane dp0s3 address 201.1.1.2/24" \
           "set interfaces tunnel tun0 encapsulation gre-multipoint" \
           "set interfaces tunnel tun0 local-ip 201.1.1.2" \
           "set interfaces tunnel tun0 address 172.30.0.1/32" > /dev/null
cli $SPOKE "set interfaces dataplane dp0s3 address 201.1.1.1/24" \
           "set interfaces tunnel tun0 encapsulation gre-multipoint" \
           "set interfaces tunnel tun0 local-ip 201.1.1.1" \
           "set interfaces tunnel tun0 address 172.30.0.2/32" > /dev/null
sleep 8
printf '  spoke tunnel dest: %s   (0.0.0.0 is the multipoint form)\n' "$(tun_dest $SPOKE)"
S $SPOKE "ping -c 2 -W 2 201.1.1.2 2>&1 | grep -oE '[0-9]+ received'" | tail -1 | sed 's/^/  underlay to hub: /'

echo; echo "===== 3. NHRP, so nhrpd starts generating registrations ====="
# debug on, because nhrpd logs nothing about registration attempts otherwise.
# The first version of this script checked "is nhrpd running" and read the tail
# of its journal, which showed only start-up lines and proved nothing about
# whether any packet was being generated. A counter that does not move is
# meaningless until the generator is known to be running.
S $SPOKE 'sudo vtysh -c "configure terminal" -c "debug nhrp all" -c "end" >/dev/null 2>&1; echo "  debug on"' | tail -1
S $HUB   'sudo vtysh -c "configure terminal" -c "interface tun0" -c "ip nhrp network-id 1" -c "ip nhrp redirect" -c "ip nhrp shortcut" -c "end" >/dev/null 2>&1; echo "  hub configured"' | tail -1
S $SPOKE 'sudo vtysh -c "configure terminal" -c "interface tun0" -c "ip nhrp network-id 1" -c "ip nhrp nhs 172.30.0.1 nbma 201.1.1.2" -c "end" >/dev/null 2>&1; echo "  spoke configured"' | tail -1

echo; echo "===== 4. tx_errors while registration retries ====="
# .spathintf is read in both directions. A TUN device counts from the kernel's
# side: tx is the kernel handing a packet to the dataplane, rx is the dataplane
# handing one back. Reading tx alone says "the packets reach the dataplane" and
# hides the fact that they come straight back, which is exactly the bounce this
# change exists to count.
sp() { S $SPOKE "cat /sys/class/net/.spathintf/statistics/$1_packets 2>/dev/null" | tail -1 | tr -dc '0-9'; }

before=$(tun_tx_errors $SPOKE); sp_tx0=$(sp tx); sp_rx0=$(sp rx)
printf '  before:    tx_errors=%s  .spathintf tx=%s rx=%s\n' \
	"${before:-?}" "${sp_tx0:-?}" "${sp_rx0:-?}"
sleep 45
after=$(tun_tx_errors $SPOKE); sp_tx1=$(sp tx); sp_rx1=$(sp rx)
printf '  after 45s: tx_errors=%s  .spathintf tx=%s rx=%s\n' \
	"${after:-?}" "${sp_tx1:-?}" "${sp_rx1:-?}"

# The generator, established rather than assumed.
regs=$(S $SPOKE "sudo journalctl -t nhrpd --no-pager --since '-47s' 2>/dev/null | grep -c Registration-Request" | tail -1 | tr -dc '0-9')
printf '  registrations sent in that window: %s\n' "${regs:-?}"

echo; echo "===== 5. Result ====="
if [ -z "${regs:-}" ] || [ "$regs" -eq 0 ]; then
	echo "  INCONCLUSIVE: nhrpd sent nothing in that window, so a counter that"
	echo "                did not move says nothing. Check that nhrpd is running"
	echo "                and that the NHS is configured."
elif [ -z "$before" ] || [ -z "$after" ]; then
	echo "  FAIL: could not read tx_errors from the tunnel"
elif [ "$after" -gt "$before" ]; then
	printf '  PASS: %s registrations, tx_errors rose by %s -- the dead end is counted\n' \
		"$regs" "$((after - before))"
	if [ -n "${sp_rx0:-}" ] && [ "$sp_rx1" -eq "$sp_rx0" ]; then
		echo "        and .spathintf rx stopped moving, i.e. the packet is no"
		echo "        longer being handed back to the kernel."
	fi
else
	printf '  FAIL: %s registrations and tx_errors did not move.\n' "$regs"
	echo "        If .spathintf rx rose by the same amount as tx, the packet is"
	echo "        still bouncing back to the kernel and the drop is not being"
	echo "        reached."
fi

echo; echo "  -- nhrpd is still sending, i.e. the generator really is running --"
S $SPOKE "sudo journalctl -t nhrpd --no-pager -n 3 2>/dev/null | sed 's/^/    /'" | tail -3
echo "  -- registration still fails, as expected: this change does not fix NHRP --"
S $SPOKE 'sudo vtysh -c "show ip nhrp nhs" 2>&1 | tail -2 | sed "s/^/    /"' | tail -2
