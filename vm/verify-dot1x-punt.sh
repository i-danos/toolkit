#!/bin/bash
# Measure what the dataplane does with EAPOL on a dataplane port.
#
# 802.1X frames carry ethertype 0x888E. The dispatch in
# pipeline/nodes/l2_ether_forward.c punts a short list to the kernel --
# ETH_P_SLOW, LLDP, and anything below ETH_P_802_3_MIN, which is 0x0600 -- and
# drops the rest:
#
#     if (unlikely(ntohs(et) > ETH_P_802_3_MIN)) {
#             /* Drop unknown protocols */
#             if_incr_unknown(pkt->in_ifp);
#             return ETHER_FORWARD_DROP;
#     }
#
# 0x888E is 34958, well above 0x0600, so EAPOL takes that branch. That is why
# hostapd sees nothing on a dataplane port: the frames never reach the kernel.
#
# The two numbers here say which side of the change the image is on, and they
# move in opposite directions:
#
#   before  rx_non_ip climbs by the number sent, tcpdump captures 0
#   after   rx_non_ip does not move, tcpdump captures the frames
#
# rx_non_ip is ifi_unknown -- if.c:3600 -- the counter that branch increments.
#
# Runs on the bgp topology, which wires R1.dp0s3 to R2.dp0s3.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-dot1x-punt.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.231; R2=192.168.203.232
IF=dp0s3
COUNT=${COUNT:-50}
HERE=$(dirname "$0")

exec > "$OUT" 2>&1
S() { docker exec danos-robot timeout 180 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$1" "$2" 2>&1; }

cli() {
	local h=$1; shift
	local c=""
	for x in "$@"; do c="$c vcli -s \$SID -c \"$x\" >/dev/null 2>&1;"; done
	S "$h" "SID=\$\$; eval \"\$(cli-shell-api getSessionEnv \$SID)\"; cli-shell-api setupSession; $c
	        vcli -s \$SID -c commit 2>&1 | grep -viE 'sssd|configuration db|grub|boot-loader|crash dump' | tail -2"
}

rx_non_ip() {
	S "$1" "sudo /opt/vyatta/bin/vplsh -l -c 'ifconfig' 2>/dev/null" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print('-1'); raise SystemExit
for i in d.get('interfaces', []):
    if i['name'] == '$IF':
        print(i.get('statistics', {}).get('rx_non_ip', -1)); break
else:
    print('-1')
"
}

echo "===== 1. Bring the R1-R2 link up ====="
cli $R1 "set interfaces dataplane $IF address 201.1.1.1/24"
cli $R2 "set interfaces dataplane $IF address 201.1.1.2/24"
sleep 5
S $R1 "ip -4 -br addr show $IF" | sed 's/^/  R1 /'
S $R2 "ip -4 -br addr show $IF" | sed 's/^/  R2 /'

echo; echo "===== 2. Install the sender on R1 ====="
b64=$(base64 -w0 "$HERE/send-eapol.py")
S $R1 "echo '$b64' | base64 -d | sudo tee /tmp/send-eapol.py >/dev/null; sudo chmod 755 /tmp/send-eapol.py; echo '  installed'; head -1 /tmp/send-eapol.py"

echo; echo "===== 3. Baseline on R2, and start a capture ====="
before=$(rx_non_ip $R2)
echo "  rx_non_ip before: $before"
# Capture unfiltered and grep afterwards. "ether proto 0x888e" as a tcpdump
# filter matched nothing through ssh into vbash, which reads exactly like the
# frames never arriving -- the unfiltered capture on the same run showed them.
S $R2 "sudo rm -f /tmp/eapol.txt; sudo sh -c 'nohup timeout 30 tcpdump -i $IF -nn -e -c 200 > /tmp/eapol.txt 2>&1 &'; echo '  capture started'"
sleep 4

echo; echo "===== 4. Send $COUNT EAPOL-Start frames from R1 ====="
# Unicast to R2's own MAC. Addressed to the PAE group instead, a punted frame
# is still dropped by local_packet_filter() unless something on R2 has joined
# that multicast -- correct behaviour, but it would hide whether the punt
# itself works.
dstmac=$(S $R2 "ip -br link show $IF | awk '{print \$3}'" | tail -1)
echo "  R2 $IF is $dstmac"
sent=$(S $R1 "sudo python3 /tmp/send-eapol.py $IF $COUNT $dstmac" | grep -oE 'sent [0-9]+')
echo "  $sent"
case "$sent" in
	"sent $COUNT") ;;
	*) echo "  the sender did not report sending $COUNT -- the counters below mean nothing" ;;
esac
sleep 6

echo; echo "===== 5. Result ====="
after=$(rx_non_ip $R2)
echo "  rx_non_ip after:  $after"
if [ "$before" -ge 0 ] && [ "$after" -ge 0 ]; then
	echo "  rx_non_ip delta:  $((after - before))"
fi
captured=$(S $R2 "sudo grep -c EAPOL /tmp/eapol.txt 2>/dev/null || echo 0" | tail -1)
echo "  captured on R2's kernel device: ${captured:-0}"
S $R2 "sudo grep EAPOL /tmp/eapol.txt 2>/dev/null | head -2" | sed 's/^/    /'

echo; echo "===== Verdict ====="
if [ "$before" -ge 0 ] && [ "$after" -ge 0 ] && [ $((after - before)) -ge "$COUNT" ]; then
	echo "  EAPOL is being dropped as an unknown protocol -- pre-change behaviour"
elif [ "${captured:-0}" -ge 1 ]; then
	echo "  EAPOL reaches the kernel -- the punt is in place"
else
	echo "  neither: the frames went somewhere else, do not draw a conclusion"
fi
