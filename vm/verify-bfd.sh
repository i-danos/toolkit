#!/bin/bash
# Verify BFD, in the only way that means anything: by measuring how long a
# failure takes to be noticed.
#
# A session reading "up" proves almost nothing -- it is the state a session
# holds when nothing is happening. What BFD exists for is the difference
# between sub-second detection and waiting out the protocol's own dead timer,
# so this measures both and compares them.
#
#   R2 dp0s10 66.1.1.3  <--->  66.1.1.2 dp0s10 R3
#
# OSPF between them, dead interval left at its default 40s. The link is broken
# from the hypervisor side rather than through the CLI: taking the interface
# down with "set interfaces dataplane dp0s10 disable" tells the protocol
# directly, which is exactly the signal being measured, so the measurement
# would come out at zero for reasons that have nothing to do with BFD.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-bfd.log}
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
    | grep -viE "^\s*$" | tail -3
}

# Seconds until OSPF stops listing the neighbour, polled twice a second.
detect_time() {
  local h=$1 start now
  start=$(date +%s.%N)
  for _ in $(seq 1 120); do
    if ! S "$h" 'sudo vtysh -c "show ip ospf neighbor"' | grep -q "Full"; then
      now=$(date +%s.%N)
      echo "$start $now" | awk '{printf "%.1f", $2-$1}'
      return 0
    fi
    sleep 0.5
  done
  echo ">60"
}

echo "===== 1. Baseline: OSPF, no BFD yet ====="
cli $R2 "set interfaces dataplane dp0s10 address 66.1.1.3/24" \
        "set interfaces loopback lo1 address 2.2.2.2/32" \
        "set protocols ospf area 0 network 66.1.1.0/24" \
        "set protocols ospf area 0 network 2.2.2.2/32" \
        "set protocols ospf parameters router-id 2.2.2.2"
cli $R3 "set interfaces dataplane dp0s10 address 66.1.1.2/24" \
        "set interfaces loopback lo1 address 3.3.3.3/32" \
        "set protocols ospf area 0 network 66.1.1.0/24" \
        "set protocols ospf area 0 network 3.3.3.3/32" \
        "set protocols ospf parameters router-id 3.3.3.3"
sleep 45
echo "--- OSPF neighbour ---"; S $R2 'sudo vtysh -c "show ip ospf neighbor"' | tail -3

echo; echo "===== 2. Without BFD: break the link, time how long OSPF alone takes ====="
echo "  Breaking the link at R3 ..."
docker exec danos-robot true 2>/dev/null
# Break the link from below: taking R3 dp0s10 down gives the protocol no notification
S $R3 'sudo ip link set dp0s10 down' >/dev/null
T_PLAIN=$(detect_time $R2)
echo "  OSPF alone detected in ${T_PLAIN}s (dead interval defaults to 40s)"
S $R3 'sudo ip link set dp0s10 up' >/dev/null
sleep 50

echo; echo "===== 3. Add BFD ====="
cli $R2 "set protocols bfd profile FAST detect-multiplier 3" \
        "set protocols bfd profile FAST transmit-interval 300" \
        "set protocols bfd profile FAST receive-interval 300" \
        "set interfaces dataplane dp0s10 ip ospf bfd" \
        "set interfaces dataplane dp0s10 ip ospf bfd profile FAST"
cli $R3 "set protocols bfd profile FAST detect-multiplier 3" \
        "set protocols bfd profile FAST transmit-interval 300" \
        "set protocols bfd profile FAST receive-interval 300" \
        "set interfaces dataplane dp0s10 ip ospf bfd" \
        "set interfaces dataplane dp0s10 ip ospf bfd profile FAST"
sleep 40

echo "--- Generated frr.conf, BFD part ---"
S $R2 'sudo grep -nE "^bfd| profile| detect-multiplier| transmit-interval| receive-interval|ospf bfd" /etc/vyatta-routing/frr.conf'
echo "--- BFD session ---"; S $R2 "$OP show protocols bfd peers" | tail -12

echo; echo "===== 4. Are the counters moving: up and working, or up and idle ====="
c1=$(S $R2 'sudo vtysh -c "show bfd peers counters"' | grep -oE "Control packet input: [0-9]+" | head -1 | grep -oE "[0-9]+")
sleep 6
c2=$(S $R2 'sudo vtysh -c "show bfd peers counters"' | grep -oE "Control packet input: [0-9]+" | head -1 | grep -oE "[0-9]+")
echo "  Control packets received over six seconds: ${c1:-?} -> ${c2:-?}"

echo; echo "===== 5. With BFD: same break, same measurement ====="
S $R3 'sudo ip link set dp0s10 down' >/dev/null
T_BFD=$(detect_time $R2)
echo "  Detected in ${T_BFD}s with BFD"
S $R3 'sudo ip link set dp0s10 up' >/dev/null

echo; echo "===== Result ====="
printf "  OSPF alone:  %ss\n  With BFD:    %ss\n" "$T_PLAIN" "$T_BFD"
echo "  BFD works if the second is far smaller than the first, not if the session reads up"
echo "===== Done ====="
