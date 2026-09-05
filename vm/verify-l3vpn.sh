#!/bin/bash
# End-to-end MPLS L3VPN across two PEs.
#
#   R1 (PE1)            R2 (P)            R3 (PE2)
#   lo1 1.1.1.1         lo1 2.2.2.2       lo1 3.3.3.3
#   dp0s9 65.1.1.2 ---- dp0s9 65.1.1.3
#                       dp0s10 66.1.1.3 - dp0s10 66.1.1.2
#   dp0s8 VRF red                         dp0s9 VRF red
#   10.1.1.1/24                           172.16.1.1/24
#
# The LDP model requires a label allocation policy -- "Exactly one allocation
# policy must be defined" -- and leaving it out fails the whole commit, taking
# the OSPF configuration in the same transaction with it. host-routes is the
# one L3VPN wants: labels for the loopback host routes the VPN nexthops
# resolve through.
#
# Core: OSPF plus LDP in the global table. R2 is a pure P router and holds no
# VRF and no BGP -- if it needed either, the labels would not be doing their
# job.
#
# PE-PE: one iBGP session between the loopbacks, carrying VPN-IPv4. This is
# what the vpnv4-unicast address family added; before it a VRF could be fully
# configured and the tagged routes had nowhere to go.
#
# The result is judged on three levels, and stopping at the second proves
# nothing about forwarding:
#
#   1. LDP adjacency and label bindings in the core
#   2. the VPN-IPv4 session up, and PE1's VRF prefix present in PE2's VRF table
#      carrying the right route distinguisher
#   3. traffic actually crossing between the two VRFs
#
# label vpn-export is not optional. Without it a PE advertises implicit-null
# for its VPN routes, which tells the far end not to push a VPN label at all.
# Everything up to and including level 2 then looks correct -- session up, RD
# and RT right, route installed in the remote VRF -- and forwarding still
# fails, because the packet arrives carrying no label to demultiplex on. That
# is exactly how this first came out: 50 packets left PE1, 80 arrived at PE2's
# core interface, and 0 reached the VRF.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-l3vpn.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.155; R2=192.168.203.156; R3=192.168.203.157
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

echo "===== 1. Core: OSPF and LDP in the global table ====="
echo "--- R1 (PE1) ---"
cli $R1 "set interfaces dataplane dp0s9 address 65.1.1.2/24" \
        "set interfaces loopback lo1 address 1.1.1.1/32" \
        "set protocols ospf area 0 network 65.1.1.0/24" \
        "set protocols ospf area 0 network 1.1.1.1/32" \
        "set protocols ospf parameters router-id 1.1.1.1" \
        "set protocols mpls-ldp lsr-id 1.1.1.1" \
        "set protocols mpls-ldp address-family ipv4 transport-address 1.1.1.1" \
        "set protocols mpls-ldp address-family ipv4 label-policy allocate host-routes" \
        "set protocols mpls-ldp address-family ipv4 discovery interfaces interface dp0s9"
echo "--- R2 (P) ---"
cli $R2 "set interfaces dataplane dp0s9 address 65.1.1.3/24" \
        "set interfaces dataplane dp0s10 address 66.1.1.3/24" \
        "set interfaces loopback lo1 address 2.2.2.2/32" \
        "set protocols ospf area 0 network 65.1.1.0/24" \
        "set protocols ospf area 0 network 66.1.1.0/24" \
        "set protocols ospf area 0 network 2.2.2.2/32" \
        "set protocols ospf parameters router-id 2.2.2.2" \
        "set protocols mpls-ldp lsr-id 2.2.2.2" \
        "set protocols mpls-ldp address-family ipv4 transport-address 2.2.2.2" \
        "set protocols mpls-ldp address-family ipv4 label-policy allocate host-routes" \
        "set protocols mpls-ldp address-family ipv4 discovery interfaces interface dp0s9" \
        "set protocols mpls-ldp address-family ipv4 discovery interfaces interface dp0s10"
echo "--- R3 (PE2) ---"
cli $R3 "set interfaces dataplane dp0s10 address 66.1.1.2/24" \
        "set interfaces loopback lo1 address 3.3.3.3/32" \
        "set protocols ospf area 0 network 66.1.1.0/24" \
        "set protocols ospf area 0 network 3.3.3.3/32" \
        "set protocols ospf parameters router-id 3.3.3.3" \
        "set protocols mpls-ldp lsr-id 3.3.3.3" \
        "set protocols mpls-ldp address-family ipv4 transport-address 3.3.3.3" \
        "set protocols mpls-ldp address-family ipv4 label-policy allocate host-routes" \
        "set protocols mpls-ldp address-family ipv4 discovery interfaces interface dp0s10"

echo; echo "===== 2. Wait for the core to converge ====="
sleep 55
echo "--- R2 LDP neighbour ---"; S $R2 "$OP show protocols mpls-ldp neighbor" | tail -5
echo "--- R1 label for the PE2 loopback ---"; S $R1 'sudo vtysh -c "show mpls table"' | tail -5

echo; echo "===== 3. VRFs and the VPN-IPv4 session ====="
echo "--- R1 (PE1) ---"
cli $R1 "set routing routing-instance red instance-type vrf" \
        "set routing routing-instance red interface dp0s8" \
        "set interfaces dataplane dp0s8 address 10.1.1.1/24" \
        "set routing routing-instance red protocols bgp 65001 parameters router-id 1.1.1.1" \
        "set routing routing-instance red protocols bgp 65001 address-family ipv4-unicast route-distinguisher 65001:100" \
        "set routing routing-instance red protocols bgp 65001 address-family ipv4-unicast label vpn-export auto" \
        "set routing routing-instance red protocols bgp 65001 address-family ipv4-unicast route-target 65001:100 type both" \
        "set routing routing-instance red protocols bgp 65001 address-family ipv4-unicast network 10.1.1.0/24" \
        "set protocols bgp 65001 parameters router-id 1.1.1.1" \
        "set protocols bgp 65001 neighbor 3.3.3.3 remote-as 65001" \
        "set protocols bgp 65001 neighbor 3.3.3.3 update-source lo1" \
        "set protocols bgp 65001 neighbor 3.3.3.3 address-family vpnv4-unicast"
echo "--- R3 (PE2) ---"
cli $R3 "set routing routing-instance red instance-type vrf" \
        "set routing routing-instance red interface dp0s9" \
        "set interfaces dataplane dp0s9 address 172.16.1.1/24" \
        "set routing routing-instance red protocols bgp 65001 parameters router-id 3.3.3.3" \
        "set routing routing-instance red protocols bgp 65001 address-family ipv4-unicast route-distinguisher 65001:300" \
        "set routing routing-instance red protocols bgp 65001 address-family ipv4-unicast label vpn-export auto" \
        "set routing routing-instance red protocols bgp 65001 address-family ipv4-unicast route-target 65001:100 type both" \
        "set routing routing-instance red protocols bgp 65001 address-family ipv4-unicast network 172.16.1.0/24" \
        "set protocols bgp 65001 parameters router-id 3.3.3.3" \
        "set protocols bgp 65001 neighbor 1.1.1.1 remote-as 65001" \
        "set protocols bgp 65001 neighbor 1.1.1.1 update-source lo1" \
        "set protocols bgp 65001 neighbor 1.1.1.1 address-family vpnv4-unicast"

echo; echo "===== 4. Generated frr.conf, R1 VPN part ====="
S $R1 'sudo grep -nE "address-family ipv4 vpn|rd vpn|rt vpn|import vpn|export vpn|activate|router bgp" /etc/vyatta-routing/frr.conf'

echo; echo "===== 5. Wait for BGP to converge ====="
sleep 60
echo "--- VPN-IPv4 session on R1 ---"
S $R1 'sudo vtysh -c "show bgp ipv4 vpn summary"' | tail -6
echo "--- R3 VRF red route table, should hold R1's 10.1.1.0/24 ---"
S $R3 'sudo vtysh -c "show ip route vrf vrfred"' | grep -E "10\.1\.1|B>" | head -4
echo "--- The VPN route R3 received, with its RD ---"
S $R3 'sudo vtysh -c "show bgp ipv4 vpn"' | grep -E "65001:100|10\.1\.1" | head -4

echo; echo "===== 6. Forwarding: ping PE2's VRF from PE1's VRF ====="
# ip vrf exec, not "vrf exec". The latter does not exist here and fails as
# "command not found", which a || fallback does not catch the way a non-zero
# exit would -- the run reported it as the forwarding result twice before the
# command name was checked.
S $R1 'sudo ip vrf exec vrfred ping -c 5 -W 2 -I 10.1.1.1 172.16.1.1 2>&1 | tail -3'

echo; echo "===== Done ====="
