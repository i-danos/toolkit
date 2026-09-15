#!/bin/bash
# How long is the hole, and does traffic actually stop in it?
#
# The scale probe sampled the data plane's route count across a reconnect and
# caught this:
#
#     t+ 3s  routes 0
#     t+ 6s  routes 2208
#
# The table empties and refills. A before-and-after reading sees 2008 -> 2208
# and calls it a successful resync.
#
# That probe's forwarding check was worthless and this exists to replace it. It
# pinged after the refill rather than during the hole, and it pinged an address
# reached over the management interface, which is kernel-owned and never went
# through the data plane at all. Two ways of measuring the wrong thing in one
# line.
#
# Here the ping runs *through* the data plane, from R3 across R1, and it runs
# for the whole window rather than after it. The route count is sampled every
# second so the hole can be timed rather than merely noticed.
#
# What this decides: whether an FPM reconnect can ever be automated. A repair
# that blanks the forwarding table is not a repair for a handful of missing
# routes, however correct the end state is.
#
# TOPO=ipsec: R1.dp0s9 <-> R2.dp0s3, R2.dp0s8 <-> R3.dp0s8.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-/home/aikon/danos/.obs/probe-resync-outage.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.155
R2=192.168.203.156
R3=192.168.203.157
N=${N:-2000}

exec > "$OUT" 2>&1
"$HERE/image-fingerprint.sh"
S() { docker exec danos-robot timeout 600 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$1" "$2" 2>&1; }

cli() {
	local h=$1; shift
	local c=""
	for x in "$@"; do c="$c vcli -s \$SID -c \"$x\" 2>&1;"; done
	S "$h" "SID=\$\$; eval \"\$(cli-shell-api getSessionEnv \$SID)\"; cli-shell-api setupSession; $c
	        vcli -s \$SID -c commit 2>&1 | grep -viE 'sssd|configuration db|grub|boot-loader|crash dump|^\s*\$'"
}

dp_count() {
	S $R1 "sudo /opt/vyatta/bin/vplsh -l -c 'dpa object show route' 2>/dev/null | python3 -c 'import sys,json
print(len(json.load(sys.stdin)[\"dpa_objects\"][\"objects\"]))' 2>/dev/null" | tail -1
}

echo "===== 1. A path that actually crosses the data plane ====="
# R3 -> R1 through R2. Nothing here touches the management interface.
cli $R1 "set interfaces dataplane dp0s9 address 10.60.60.1/24" | tail -1 | sed 's/^/    /'
cli $R2 "set interfaces dataplane dp0s3 address 10.60.60.2/24" \
        "set interfaces dataplane dp0s8 address 10.20.20.2/24" | tail -1 | sed 's/^/    /'
cli $R3 "set interfaces dataplane dp0s8 address 10.20.20.3/24" \
        "set protocols static route 10.60.60.0/24 next-hop 10.20.20.2" | tail -1 | sed 's/^/    /'
sleep 12
echo "    R3 -> R1 over the data plane:"
S $R3 "ping -c 3 -W 2 10.60.60.1 2>&1 | tail -2" | sed 's/^/      /'

echo
echo "===== 2. Load $N routes ====="
S $R1 "python3 -c '
with open(\"/tmp/bulk.conf\",\"w\") as f:
    f.write(\"configure terminal\n\")
    for i in range($N):
        f.write(\"ip route 10.%d.%d.0/24 blackhole\n\" % (128 + i // 256, i % 256))
    f.write(\"end\n\")'" > /dev/null
S $R1 "sudo vtysh -f /tmp/bulk.conf >/dev/null 2>&1; echo loaded" | tail -1 | sed 's/^/    /'
sleep 20
echo "    dataplane routes: $(dp_count)"

echo
echo "===== 3. Reconnect, sampling every second, with traffic running ====="
# The ping is started first and left running across the whole window. Its loss
# count is the only thing here that can answer "did traffic stop".
S $R3 "nohup sh -c 'ping -i 0.2 -c 150 -W 1 10.60.60.1 > /tmp/outage.txt 2>&1' >/dev/null 2>&1 &
       echo started" | tail -1 | sed 's/^/    /'
sleep 2
S $R1 "sudo vtysh -c 'configure terminal' -c 'no fpm address 127.0.0.1' >/dev/null 2>&1
       sudo vtysh -c 'configure terminal' -c 'fpm address 127.0.0.1' >/dev/null 2>&1; echo bounced" | tail -1 | sed 's/^/    /'
for i in $(seq 1 14); do
	printf '    t+%2ds  routes %s\n' "$i" "$(dp_count)"
done

echo
echo "===== 4. What the traffic saw ====="
sleep 12
S $R3 "tail -4 /tmp/outage.txt" | sed 's/^/    /'

echo
echo "===== 5. Clean up ====="
S $R1 "python3 -c '
with open(\"/tmp/bulkdel.conf\",\"w\") as f:
    f.write(\"configure terminal\n\")
    for i in range($N):
        f.write(\"no ip route 10.%d.%d.0/24 blackhole\n\" % (128 + i // 256, i % 256))
    f.write(\"end\n\")'" > /dev/null
S $R1 "sudo vtysh -f /tmp/bulkdel.conf >/dev/null 2>&1; rm -f /tmp/bulk*.conf; echo cleaned" | tail -1 | sed 's/^/    /'
cli $R3 "delete interfaces dataplane dp0s8 address 10.20.20.3/24" \
        "delete protocols static route 10.60.60.0/24" > /dev/null
cli $R2 "delete interfaces dataplane dp0s3 address 10.60.60.2/24" \
        "delete interfaces dataplane dp0s8 address 10.20.20.2/24" > /dev/null
cli $R1 "delete interfaces dataplane dp0s9 address 10.60.60.1/24" > /dev/null
S $R3 "rm -f /tmp/outage.txt" > /dev/null
sleep 8
echo "    dataplane routes: $(dp_count)"
