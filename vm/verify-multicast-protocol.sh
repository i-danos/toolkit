#!/bin/bash
# Functional verification, second attempt. The first had two faults of its own
# and neither was in the product:
#
#   - it referenced a prefix list, SSM-RANGE, that did not exist. The leafref
#     rejected it and took the whole R2 commit with it, so nothing on R2 was
#     configured at all. BSR electing nothing, MSDP sitting in listen on one
#     side only and zero IPv6 neighbours all followed from that, and none of
#     them said anything about the feature.
#   - it used "ipv6 address", which DANOS does not have. Addresses of both
#     families go under the interface's single "address" node; the "ipv6" node
#     carries protocol configuration only.
#
# The prefix list is now created before it is referenced, which also exercises
# the leafref in the direction that should succeed.
#
# Two more things this has to set up itself, learned by leaving them out:
#
#   - OSPF on both routers. Without it there is no route to the other end's
#     loopback, and the MSDP session goes out the management interface into
#     QEMU's user-mode stack instead, where it sits in "connecting" forever.
#     The peer addresses are loopbacks precisely because that is how MSDP is
#     deployed, so the unicast routing has to be there first.
#   - a source address on candidate-BSR. FRR's grammar makes it optional and
#     accepts the command without one, but the router then reports
#     "Address: 0.0.0.0 ... not currently operating as Candidate BSR" and no
#     election ever happens. The priority is applied and visible, which makes
#     it look configured.
#
#     Note the path: "candidate-bsr address", not "candidate-bsr source
#     address". The YANG models the four alternatives as a choice, and a
#     choice and its cases are transparent in the data tree, so the node is
#     "address". FRR's own syntax has the "source" keyword and the generated
#     line carries it -- "bsr candidate-bsr priority 200 source address
#     2.2.2.2" -- but the CLI does not.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-multicast-protocol.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R2=192.168.203.156; R3=192.168.203.157
OP=/opt/vyatta/bin/vyatta-op-cmd-wrapper

exec > "$OUT" 2>&1
S() { docker exec danos-robot timeout 180 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$1" "$2" 2>&1; }

cli() {
  local h=$1; shift
  local cmds=""
  for c in "$@"; do cmds="$cmds vcli -s \$SID -c \"$c\" 2>&1 | grep -viE '^\$';"; done
  S "$h" "SID=\$\$; eval \"\$(cli-shell-api getSessionEnv \$SID)\"; cli-shell-api setupSession; $cmds
          vcli -s \$SID -c commit 2>&1 | grep -viE 'sssd|configuration db|grub|boot-loader|crash dump'" \
    | grep -viE "^\s*$" | tail -4
}

echo "===== R2 ====="
cli $R2 "set interfaces dataplane dp0s9 address 65.1.1.3/24" \
        "set interfaces dataplane dp0s10 address 66.1.1.3/24" \
        "set interfaces loopback lo1 address 2.2.2.2/32" \
        "set protocols ospf area 0 network 65.1.1.0/24" \
        "set protocols ospf area 0 network 66.1.1.0/24" \
        "set protocols ospf area 0 network 2.2.2.2/32" \
        "set protocols ospf parameters router-id 2.2.2.2" \
        "set interfaces dataplane dp0s9 ip pim" \
        "set interfaces dataplane dp0s10 ip pim" \
        "set interfaces loopback lo1 ip pim" \
        "set policy route prefix-list SSM-RANGE rule 1 action permit" \
        "set policy route prefix-list SSM-RANGE rule 1 prefix 232.0.0.0/8" \
        "set protocols pim ssm prefix-list SSM-RANGE" \
        "set protocols pim bsr candidate-bsr priority 200" \
        "set protocols pim bsr candidate-bsr address 2.2.2.2" \
        "set protocols pim bsr candidate-rp address 2.2.2.2" \
        "set protocols pim bsr candidate-rp priority 10" \
        "set protocols pim bsr candidate-rp group 239.0.0.0/8" \
        "set protocols pim msdp peer 3.3.3.3 source-address 2.2.2.2" \
        "set interfaces dataplane dp0s10 ip pim bsm" \
        "set interfaces dataplane dp0s10 address 2001:db8:66::3/64" \
        "set interfaces dataplane dp0s10 ipv6 pim" \
        "set interfaces loopback lo1 address 2001:db8::2/128" \
        "set interfaces loopback lo1 ipv6 pim" \
        "set protocols pim6 rp 2001:db8::2 group ff00::/8"

echo; echo "===== R3 ====="
cli $R3 "set interfaces dataplane dp0s10 address 66.1.1.2/24" \
        "set interfaces dataplane dp0s9 address 172.16.1.2/24" \
        "set interfaces loopback lo1 address 3.3.3.3/32" \
        "set protocols ospf area 0 network 66.1.1.0/24" \
        "set protocols ospf area 0 network 3.3.3.3/32" \
        "set protocols ospf parameters router-id 3.3.3.3" \
        "set interfaces dataplane dp0s10 ip pim" \
        "set interfaces dataplane dp0s9 ip pim" \
        "set interfaces loopback lo1 ip pim" \
        "set interfaces dataplane dp0s10 ip pim bsm" \
        "set protocols pim msdp peer 2.2.2.2 source-address 3.3.3.3" \
        "set interfaces dataplane dp0s10 ipv6 pim" \
        "set interfaces dataplane dp0s9 address 2001:db8:72::2/64" \
        "set interfaces dataplane dp0s9 ipv6 pim" \
        "set interfaces dataplane dp0s9 ipv6 mld" \
        "set interfaces dataplane dp0s9 ipv6 mld version 2" \
        "set interfaces dataplane dp0s9 ipv6 mld join-group ff0e::1" \
        "set protocols pim6 rp 2001:db8::2 group ff00::/8"

echo; echo "===== 等收敛 ====="
sleep 110

echo; echo "--- 1. BSR（R3 视角） ---"
S $R3 "$OP show protocols pim bsr"
echo "--- R3 学到的 BSR RP ---"
S $R3 "$OP show protocols pim bsr rp-info"

echo; echo "--- 2. MSDP 会话 ---"
echo "R2:"; S $R2 "$OP show protocols msdp peer"
echo "R3:"; S $R3 "$OP show protocols msdp peer"

echo; echo "--- 3. IPv6 PIM 邻居 ---"
echo "R2:"; S $R2 "$OP show protocols pim6 neighbor"
echo "R3:"; S $R3 "$OP show protocols pim6 neighbor"

echo; echo "--- 4. SSM 组范围是否生效 ---"
S $R2 'sudo vtysh -c "show ip pim group-type" 2>&1 | head -3'

echo; echo "--- 5. MLD 加入与 PIM6 树 ---"
S $R3 "$OP show protocols mld joins" | grep -E "ff0e|Group" | head -3
S $R3 'sudo vtysh -c "show ipv6 pim state" 2>&1 | tail -4'

echo; echo "===== 完成 ====="
