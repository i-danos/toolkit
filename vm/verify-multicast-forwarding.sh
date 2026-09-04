#!/bin/bash
# Forwarding tests for SSM and for IPv6, the two gaps left by
# verify-multicast-protocol.sh. That script proves the protocols reach the
# right state; this one proves packets cross the box.
#
# The instrument is the dataplane's own tables, not "show ip mroute":
#
#   multicast mif  / mif6      interface table and per-interface counters
#   multicast route / route6   forwarding entries and which path serves them
#   multicast fcstat / fcstat6 per-entry counters
#
# Note the IPv6 spelling. The commands are "multicast mif6", not
# "multicast6 mif" -- the second is what a reasonable guess produces and it
# answers "Unknown command: multicast6", which reads as IPv6 multicast being
# absent from the dataplane. It is not; see mcast_cmds[] in
# vyatta-dataplane/src/rt_commands.c.
#
# Topology, as boot-topo.sh TOPO=fw brings it up:
#
#   R1 dp0s9 --- dp0s9 R2 dp0s10 --- dp0s10 R3 dp0s9
#   source                transit              receiver
#
# SSM needs no RP. IPv6 uses a static RP on R2's loopback and OSPFv3 for the
# unicast reachability RPF depends on.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-multicast-forwarding.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.155; R2=192.168.203.156; R3=192.168.203.157
SSM_GROUP=232.1.1.1
SSM_SOURCE=65.1.1.2
V6_GROUP=ff0e::1

SENDDIR=$(cd "$(dirname "$0")" && pwd)

exec > "$OUT" 2>&1
S() { docker exec danos-robot timeout 180 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$1" "$2" 2>&1; }

cli() {
  local h=$1; shift
  local cmds=""
  for c in "$@"; do cmds="$cmds vcli -s \$SID -c \"$c\" 2>&1 | grep -viE '^\$';"; done
  S "$h" "SID=\$\$; eval \"\$(cli-shell-api getSessionEnv \$SID)\"; cli-shell-api setupSession; $cmds
          vcli -s \$SID -c commit 2>&1 | grep -viE 'sssd|configuration db|grub|boot-loader|crash dump'" \
    | grep -viE "^\s*$" | tail -3
}


# The sender goes over as a file rather than as python3 -c. Inline, it passes
# through this shell, ssh and vbash, and the quoting did not survive: the
# command produced no output at all -- not even an error -- and the run
# continued to counters that were legitimately zero because nothing had been
# sent. A silent no-op is the worst possible failure here, since zero counters
# is exactly what a broken forwarding path looks like, so this asserts the
# send happened before anything is read.
send() {
  local h=$1 script=$2 args=$3
  docker cp "$SENDDIR/$script" danos-robot:/tmp/ >/dev/null 2>&1
  docker exec danos-robot timeout 60 sshpass -p vyatta \
    scp $SSH_OPTS "/tmp/$script" "vyatta@$h:/tmp/" >/dev/null 2>&1
  local out
  out=$(S "$h" "python3 /tmp/$script $args")
  if printf '%s' "$out" | grep -q "^sent "; then
    echo "  $out"
  else
    echo "  发送失败，后面的计数无意义: ${out:-（无输出）}"
    return 1
  fi
}

# Counters for one router, both families, as "iface in out punt".
counters() {
  local h=$1 cmd=$2
  # The JSON key follows the command: "mif" returns {"mif": [...]}, "mif6"
  # returns {"mif6": [...]}. Hardcoding "mif" made the IPv6 pass print nothing
  # at all, which looked like the dataplane having no IPv6 interfaces.
  S "$h" "sudo /opt/vyatta/bin/vplsh -l -c \"multicast $cmd\"" | python3 -c "
import sys, json
key = '$cmd'
try:
    d = json.load(sys.stdin)
except Exception as e:
    print('    解析失败:', e); raise SystemExit
for m in d.get(key, []):
    print('    %-8s in=%-7d out=%-7d punt=%d' % (m['interface'], m['pkt_in'], m['pkt_out'], m['pkt_out_punt']))
"
}

echo "===== 1. IPv4 SSM 配置 ====="
echo "--- R1（源侧） ---"
cli $R1 "set interfaces dataplane dp0s9 address 65.1.1.2/24" \
        "set interfaces loopback lo1 address 1.1.1.1/32" \
        "set protocols ospf area 0 network 65.1.1.0/24" \
        "set protocols ospf area 0 network 1.1.1.1/32" \
        "set protocols ospf parameters router-id 1.1.1.1" \
        "set policy route prefix-list SSM-RANGE rule 1 action permit" \
        "set policy route prefix-list SSM-RANGE rule 1 prefix 232.0.0.0/8" \
        "set protocols pim ssm prefix-list SSM-RANGE" \
        "set interfaces dataplane dp0s9 ip pim" \
        "set interfaces loopback lo1 ip pim"
echo "--- R2（中转） ---"
cli $R2 "set policy route prefix-list SSM-RANGE rule 1 action permit" \
        "set policy route prefix-list SSM-RANGE rule 1 prefix 232.0.0.0/8" \
        "set protocols pim ssm prefix-list SSM-RANGE"
echo "--- R3（接收侧，IGMPv3 源特定加入） ---"
cli $R3 "set policy route prefix-list SSM-RANGE rule 1 action permit" \
        "set policy route prefix-list SSM-RANGE rule 1 prefix 232.0.0.0/8" \
        "set protocols pim ssm prefix-list SSM-RANGE" \
        "set interfaces dataplane dp0s9 ip igmp" \
        "set interfaces dataplane dp0s9 ip igmp version 3" \
        "set interfaces dataplane dp0s9 ip igmp join-group $SSM_GROUP source $SSM_SOURCE"

echo; echo "===== 2. 等 SSM 树建立 ====="
sleep 45
echo "--- R3 的 (S,G) 加入 ---"
S $R3 "sudo vtysh -c \"show ip igmp join\"" | grep -E "$SSM_GROUP|Interface" | head -3
echo "--- R2 的 mroute ---"
S $R2 "sudo vtysh -c \"show ip mroute\"" | grep -E "$SSM_GROUP|Source" | head -3

echo; echo "===== 3. SSM 发送前计数 ====="
echo "R2:"; counters $R2 mif
echo "R3:"; counters $R3 mif

echo; echo "===== 4. R1 向 $SSM_GROUP 发 5000 包 ====="
send $R1 send4.py "$SSM_GROUP $SSM_SOURCE 5000"
sleep 3

echo; echo "===== 5. SSM 发送后计数 ====="
echo "R2:"; counters $R2 mif
echo "R3:"; counters $R3 mif
echo "--- R2 的 SSM 转发表项 ---"
S $R2 'sudo /opt/vyatta/bin/vplsh -l -c "multicast route"' | grep -E "source|group|input|output|forwarding" | tail -5
echo "--- R2 的 fcstat（该表项的包数/错误接口计数） ---"
S $R2 'sudo /opt/vyatta/bin/vplsh -l -c "multicast fcstat"' | python3 -c "
import sys, json
for e in json.load(sys.stdin).get('fcstat', []):
    if e['origin'] != '0.0.0.0':
        print('    %s -> %s  packets=%d bytes=%d wrong_if=%d punted=%d' %
              (e['origin'], e['group'], e['packets'], e['bytes'], e['wrong_if'], e['punted']))
"

echo; echo "===== 6. IPv6 配置 ====="
echo "--- R1 ---"
cli $R1 "set interfaces dataplane dp0s9 address 2001:db8:65::2/64" \
        "set interfaces loopback lo1 address 2001:db8::1/128" \
        "set protocols ospfv3 area 0 interface dp0s9" \
        "set protocols ospfv3 area 0 interface lo1" \
        "set interfaces dataplane dp0s9 ipv6 pim" \
        "set interfaces loopback lo1 ipv6 pim" \
        "set protocols pim6 rp 2001:db8::2 group ff00::/8"
echo "--- R2（RP） ---"
cli $R2 "set interfaces dataplane dp0s9 address 2001:db8:65::3/64" \
        "set interfaces dataplane dp0s10 address 2001:db8:66::3/64" \
        "set interfaces loopback lo1 address 2001:db8::2/128" \
        "set protocols ospfv3 area 0 interface dp0s9" \
        "set protocols ospfv3 area 0 interface dp0s10" \
        "set protocols ospfv3 area 0 interface lo1" \
        "set interfaces dataplane dp0s9 ipv6 pim" \
        "set interfaces dataplane dp0s10 ipv6 pim" \
        "set interfaces loopback lo1 ipv6 pim" \
        "set protocols pim6 rp 2001:db8::2 group ff00::/8"
echo "--- R3（接收侧） ---"
cli $R3 "set interfaces dataplane dp0s10 address 2001:db8:66::2/64" \
        "set interfaces dataplane dp0s9 address 2001:db8:72::2/64" \
        "set interfaces loopback lo1 address 2001:db8::3/128" \
        "set protocols ospfv3 area 0 interface dp0s10" \
        "set protocols ospfv3 area 0 interface dp0s9" \
        "set protocols ospfv3 area 0 interface lo1" \
        "set interfaces dataplane dp0s10 ipv6 pim" \
        "set interfaces dataplane dp0s9 ipv6 pim" \
        "set interfaces loopback lo1 ipv6 pim" \
        "set interfaces dataplane dp0s9 ipv6 mld" \
        "set interfaces dataplane dp0s9 ipv6 mld version 2" \
        "set interfaces dataplane dp0s9 ipv6 mld join-group $V6_GROUP" \
        "set protocols pim6 rp 2001:db8::2 group ff00::/8"

echo; echo "===== 7. 等 IPv6 收敛 ====="
sleep 60
echo "--- R1 是否有到 RP 的 IPv6 路由 ---"
S $R1 'sudo vtysh -c "show ipv6 route 2001:db8::2/128"' | tail -4
echo "--- R2 的 PIM6 邻居 ---"
S $R2 'sudo vtysh -c "show ipv6 pim neighbor"' | tail -4
echo "--- R2 的 IPv6 mroute ---"
S $R2 'sudo vtysh -c "show ipv6 mroute"' | tail -4

echo; echo "===== 8. IPv6 发送前计数 ====="
echo "R2:"; counters $R2 mif6
echo "R3:"; counters $R3 mif6

echo; echo "===== 9. R1 向 $V6_GROUP 发 5000 包 ====="
send $R1 send6.py "$V6_GROUP dp0s9 5000"
sleep 3

echo; echo "===== 10. IPv6 发送后计数 ====="
echo "R2:"; counters $R2 mif6
echo "R3:"; counters $R3 mif6
echo "--- R2 的 IPv6 转发表项 ---"
S $R2 'sudo /opt/vyatta/bin/vplsh -l -c "multicast route6"' | grep -E "source|group|input|output|forwarding" | tail -5
echo "--- R2 的 fcstat6 ---"
S $R2 'sudo /opt/vyatta/bin/vplsh -l -c "multicast fcstat6"' | head -20

echo; echo "===== 完成 ====="
