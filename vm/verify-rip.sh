#!/bin/bash
# End-to-end RIP over the R2-R3 link, configured only through the DANOS CLI.
#
#   R2  dp0s10 66.1.1.3   lo1 2.2.2.2/32
#   R3  dp0s10 66.1.1.2   lo1 3.3.3.3/32   lo2 9.9.9.9/32
#
# No OSPF anywhere in this test, deliberately. RIP's administrative distance is
# 120 and OSPF's is 110, so with both running a prefix carried by each is
# installed by OSPF and the kernel route reads "proto ospf". That happened
# during the manual check and looked at first like RIP not working: RIP had in
# fact learned the route and lost the election. lo2 exists for the same reason
# -- a prefix only RIP carries, so the reading is unambiguous.
#
# Judged on three levels:
#   1. the CLI generates a router rip block FRR accepts
#   2. the neighbour appears and the route is learned
#   3. the route reaches the dataplane as proto rip and forwards
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-rip.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R2=192.168.203.156; R3=192.168.203.157
OP=/opt/vyatta/bin/vyatta-op-cmd-wrapper

exec > "$OUT" 2>&1
S() { docker exec danos-robot timeout 180 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$1" "$2" 2>&1; }

cli() {
  local h=$1; shift
  local cmds=""
  for c in "$@"; do cmds="$cmds echo \"+ $c\"; vcli -s \$SID -c \"$c\" 2>&1;"; done
  S "$h" "SID=\$\$; eval \"\$(cli-shell-api getSessionEnv \$SID)\"; cli-shell-api setupSession; $cmds
          echo '+ commit'; vcli -s \$SID -c commit 2>&1 | grep -viE 'sssd|configuration db|grub|boot-loader|crash dump'" \
    | grep -viE "^\s*$"
}

echo "===== 1. Does ripd start from the image ====="
for h in $R2 $R3; do
  printf '  %-16s ' "$h"
  S "$h" 'printf "ripd=%s  rip in op tree=%s\n" "$(pgrep -c ripd)" \
            "$(/opt/vyatta/bin/opc -op=children show protocols | tr " " "\n" | grep -cx rip)"' | tail -1
done

echo; echo "===== 2. Configure RIP through the CLI ====="
echo "--- R2 ---"
cli $R2 "set interfaces dataplane dp0s10 address 66.1.1.3/24" \
        "set interfaces loopback lo1 address 2.2.2.2/32" \
        "set protocols rip network 66.1.1.0/24" \
        "set protocols rip network 2.2.2.2/32" \
        "set protocols rip version 2"
echo "--- R3, with lo2 as a RIP-only prefix ---"
cli $R3 "set interfaces dataplane dp0s10 address 66.1.1.2/24" \
        "set interfaces loopback lo1 address 3.3.3.3/32" \
        "set interfaces loopback lo2 address 9.9.9.9/32" \
        "set protocols rip network 66.1.1.0/24" \
        "set protocols rip network 3.3.3.3/32" \
        "set protocols rip network 9.9.9.9/32" \
        "set protocols rip version 2"

echo; echo "===== 3. The frr.conf the commit generated ====="
S $R2 'sudo sed -n "/^router rip/,/^exit/p" /etc/vyatta-routing/frr.conf'

echo; echo "===== 4. Wait for RIP to converge, update period is 30s ====="
sleep 75
echo "--- R2 RIP table ---"
S $R2 "$OP show protocols rip" | tail -8
echo "--- R2 RIP status: timers, interfaces, neighbours ---"
S $R2 "$OP show protocols rip status" | grep -A4 "Routing Information Sources" | tail -4

echo; echo "===== 5. Level 3: does 9.9.9.9 reach the dataplane as proto rip ====="
echo "--- kernel ---"
S $R2 'ip route show 9.9.9.9 2>&1'
echo "--- dataplane ---"
S $R2 'sudo /opt/vyatta/bin/vplsh -l -c "route show"' | python3 -c "
import sys, json
found = False
for r in json.load(sys.stdin).get('route_show', []):
    if r['prefix'].startswith('9.9.9.9'):
        nh = r.get('next_hop', [{}])[0]
        print('    %s  %s  via=%s  if=%s' % (r['prefix'], nh.get('state',''), nh.get('via','-'), nh.get('ifname','-')))
        found = True
if not found:
    print('    9.9.9.9/32 not in the dataplane route table')
"
echo "--- forwarding ---"
S $R2 'ping -c 5 -W 2 9.9.9.9 2>&1 | tail -2'

echo; echo "===== Done ====="
