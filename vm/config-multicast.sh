#!/bin/bash
# End-to-end for the second round of multicast CLI work: BSR, Auto-RP, MSDP and
# SSM on IPv4, and PIM6 plus MLD on IPv6.
#
# Everything goes through set and commit. The offline checks already showed that
# parser.py emits the right lines and that the shipping FRR accepts every one of
# them; what only a router can show is that a DANOS commit produces them, which
# is the step the VCI component registration governs.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/config-multicast.log}
VM=$(cd "$(dirname "$0")" && pwd)
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.155; R2=192.168.203.156; R3=192.168.203.157

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

echo "===== 1. Prepare the three routers ====="
sleep 110
for r in r1 r2 r3; do "$VM/prep-router.sh" /home/aikon/danos/.obs/run/$r/console.sock > /tmp/p-$r.$$ 2>&1 & done
wait
for r in r1 r2 r3; do printf '  %-4s ' "$r"; grep -hoE "NOPASSWD_OK|NOPASSWD_FAILED" /tmp/p-$r.$$ | tail -1; rm -f /tmp/p-$r.$$; done

echo; echo "===== 2. Does pim6d start from the image ====="
for h in $R1 $R2 $R3; do
  printf '  %-16s ' "$h"
  S "$h" 'printf "pimd=%s pim6d=%s\n" "$(pgrep -c pimd)" "$(pgrep -c pim6d)"' | tail -1
done

echo; echo "===== 3. New nodes in the operational tree ====="
S $R2 '/opt/vyatta/bin/opc -op=children show protocols'

echo; echo "===== 4. IPv4: BSR / Auto-RP / MSDP / SSM through the CLI ====="
cli $R2 "set interfaces dataplane dp0s9 address 65.1.1.3/24" \
        "set interfaces dataplane dp0s10 address 66.1.1.3/24" \
        "set interfaces loopback lo1 address 2.2.2.2/32" \
        "set protocols ospf area 0 network 65.1.1.0/24" \
        "set protocols ospf area 0 network 66.1.1.0/24" \
        "set protocols ospf area 0 network 2.2.2.2/32" \
        "set protocols ospf parameters router-id 2.2.2.2" \
        "set interfaces dataplane dp0s9 ip pim" \
        "set interfaces dataplane dp0s10 ip pim" \
        "set interfaces dataplane dp0s10 ip pim bsm" \
        "set interfaces dataplane dp0s10 ip pim unicast-bsm" \
        "set interfaces dataplane dp0s9 ip pim passive" \
        "set interfaces loopback lo1 ip pim" \
        "set protocols pim bsr candidate-bsr priority 64" \
        "set protocols pim bsr candidate-bsr source address 2.2.2.2" \
        "set protocols pim bsr candidate-rp priority 20" \
        "set protocols pim bsr candidate-rp interval 60" \
        "set protocols pim bsr candidate-rp source loopback" \
        "set protocols pim bsr candidate-rp group 239.0.0.0/8" \
        "set protocols pim autorp discovery" \
        "set protocols pim autorp announce scope 31" \
        "set protocols pim autorp announce rp-address 2.2.2.2 group 239.1.0.0/16" \
        "set protocols pim msdp peer 3.3.3.3 source-address 2.2.2.2" \
        "set protocols pim msdp peer 3.3.3.3 sa-limit 1000" \
        "set protocols pim msdp mesh-group MESH1 source-address 2.2.2.2" \
        "set protocols pim msdp mesh-group MESH1 member 4.4.4.4" \
        "set protocols pim msdp timers keep-alive 60" \
        "set protocols pim msdp timers hold-time 75" \
        "set protocols pim msdp log sa-events" \
        "set protocols pim ssmpingd 2.2.2.2" \
        "set interfaces dataplane dp0s9 ip igmp" \
        "set interfaces dataplane dp0s9 ip igmp version 3"

echo; echo "===== 5. IPv6: PIM6 / MLD / embedded-RP through the CLI ====="
cli $R2 "set interfaces dataplane dp0s9 ipv6 address 2001:db8:65::3/64" \
        "set interfaces dataplane dp0s10 ipv6 address 2001:db8:66::3/64" \
        "set interfaces loopback lo1 ipv6 address 2001:db8::2/128" \
        "set protocols pim6 rp 2001:db8::2 group ff00::/8" \
        "set protocols pim6 keep-alive-timer 210" \
        "set protocols pim6 embedded-rp" \
        "set protocols pim6 embedded-rp limit 100" \
        "set protocols pim6 bsr candidate-bsr priority 64" \
        "set protocols pim6 bsr candidate-rp priority 20" \
        "set protocols pim6 bsr candidate-rp source loopback" \
        "set protocols pim6 ssmpingd 2001:db8::2" \
        "set interfaces dataplane dp0s9 ipv6 pim" \
        "set interfaces dataplane dp0s9 ipv6 pim hello-interval 30" \
        "set interfaces dataplane dp0s10 ipv6 pim" \
        "set interfaces dataplane dp0s10 ipv6 pim dr-priority 200" \
        "set interfaces loopback lo1 ipv6 pim" \
        "set interfaces dataplane dp0s9 ipv6 mld" \
        "set interfaces dataplane dp0s9 ipv6 mld version 2" \
        "set interfaces dataplane dp0s9 ipv6 mld query-interval 125" \
        "set interfaces dataplane dp0s9 ipv6 mld join-group ff0e::1"

echo; echo "===== 6. The frr.conf that commit generated ====="
S $R2 'sudo cat /etc/vyatta-routing/frr.conf'

echo; echo "===== 7. FRR running config, to confirm it actually loaded ====="
S $R2 'sudo vtysh -c "show running-config" 2>/dev/null | sed -n "/^router pim/,/^end/p"'

echo; echo "===== 8. The new operational commands ====="
OP=/opt/vyatta/bin/vyatta-op-cmd-wrapper
for c in "show protocols pim bsr" "show protocols pim rp-info" \
         "show protocols pim6 interface" "show protocols pim6 rp-info" \
         "show protocols mld interface" "show protocols mld groups"; do
  echo "--- $c ---"
  S $R2 "$OP $c" | head -6
done

echo; echo "===== Done ====="
