#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-only
# Guest side of frr-nhg-ab.py. Runs as root on one router of TOPO=nhg for DURATION seconds and writes /tmp/nhg/*.
#
# usage: frr-nhg-guest.sh ROLE DURATION        ROLE is r1, r2 or r3
#
#   r1  router under test. Logs the KERNEL route to 10.255.2.1 (what router-originated traffic uses) and the carrier of dp0s9/dp0s10, and
#       originates 8 ping flows, one per source address 10.255.1.1-8, to 10.255.2.1.
#   r2  the far end. The same for 10.255.1.1, flows from 10.255.2.1-8 to 10.255.1.1.
#   r3  traffic source behind r1: 8 flows from 10.255.3.1-8 to 10.255.2.1. These are FORWARDED by r1 (data plane), not originated by it.
#
# Kernel multipath hashing here is by (source, destination) address pair, so one source address is one member of the group: eight sources
# put some flows on each member of a two-member group, and a flow on the dead member is the one that shows a stuck kernel route.
#
# Files (all times are this guest's CLOCK_REALTIME, seconds with microseconds):
#   route.log   t|carrier dp0s9|carrier dp0s10|ip route show PREFIX   written on every change and as a heartbeat every second
#   nh.log      N|t|... the output of `ip nexthop show` right after each change of the route's nhid, so group membership at that moment is known
#   snap.log    every 5 s: ip -d route show, ip nexthop show, FRR's own RIB entry (vtysh) -- the same three views DEFECTS.md used
#   ping-SRC-DST.log   ping -D output (a timestamp in front of every reply)
#   start.txt   the guest's time when this script started (S0) and the version of frr that is running
set -u
ROLE=${1:?role}; DUR=${2:?duration}
D=/tmp/nhg; rm -rf "$D"; mkdir -p "$D"
S0=$EPOCHREALTIME
{ echo "S0=$S0"; echo "role=$ROLE"; vtysh -c 'show version' 2>/dev/null | head -1; dpkg-query -W -f='frr_pkg=${Version}\n' frr 2>/dev/null; } > "$D/start.txt"

case "$ROLE" in
  r1) PFX=10.255.2.1; SRCNET=10.255.1; DST=10.255.2.1 ;;
  r2) PFX=10.255.1.1; SRCNET=10.255.2; DST=10.255.1.1 ;;
  r3) PFX=;           SRCNET=10.255.3; DST=10.255.2.1 ;;
  *) echo "bad role" >&2; exit 2 ;;
esac

pids=()
for i in 1 2 3 4 5 6 7 8; do
  timeout "$DUR" ping -D -n -i 0.05 -W 1 -I "$SRCNET.$i" "$DST" > "$D/ping-$SRCNET.$i-$DST.log" 2>&1 &
  pids+=($!)
done

if [ -n "$PFX" ]; then
  (
    END=$(( EPOCHSECONDS + DUR ))
    last=""; lastid=""; lastbeat=0; lastsnap=0
    while [ "$EPOCHSECONDS" -lt "$END" ]; do
      t=$EPOCHREALTIME
      rt=$(ip route show "$PFX" 2>&1)
      read -r c9 < /sys/class/net/dp0s9/carrier 2>/dev/null || c9=x
      read -r c10 < /sys/class/net/dp0s10/carrier 2>/dev/null || c10=x
      cur="$c9|$c10|$rt"
      if [ "$cur" != "$last" ] || [ "$EPOCHSECONDS" != "$lastbeat" ]; then
        echo "$t|$cur" >> "$D/route.log"; last=$cur; lastbeat=$EPOCHSECONDS
      fi
      id=${rt#*nhid }; id=${id%% *}
      if [ "$id" != "$lastid" ]; then
        { echo "N|$t|nhid=$id"; ip nexthop show 2>&1 | sed 's/^/N|/'; } >> "$D/nh.log"; lastid=$id
      fi
      if [ $(( EPOCHSECONDS - lastsnap )) -ge 5 ]; then
        { echo "SNAP|$t"; ip -d route show "$PFX" 2>&1; ip nexthop show 2>&1; vtysh -c "show ip route $PFX/32" 2>&1 | head -14; } >> "$D/snap.log"
        lastsnap=$EPOCHSECONDS
      fi
      sleep 0.02
    done
  ) &
  pids+=($!)
fi

wait "${pids[@]}" 2>/dev/null
echo "end=$EPOCHREALTIME" >> "$D/start.txt"
