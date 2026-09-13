#!/bin/bash
# Boot a topology and prepare every router in it, or fail loudly.
#
# Booting and prepping were open-coded in every pipeline, and every copy of
# them carried on regardless of the result. A router that does not prepare is
# not reachable by the suites, and the suites then report a mixture:
#
#     ipsec  pass=5 fail=5          one router of three missing
#     mpls   pass=5 fail=6
#     fw     pass=16 fail=0         a later topology, booted cleanly
#
# which reads as a regression in two features and not as an unprepared router.
# A run that produced 0 of 16 on FIREWALL and 1 of 15 on BGP earlier the same
# day had the same cause and was nearly read as a product failure.
#
# So: prepare every router, check the count of dataplane ports each one ends up
# with against what the topology says it should have, and exit non-zero if
# anything is short. A pipeline that stops here costs one topology; a pipeline
# that continues costs the credibility of everything it prints afterwards.
#
# Usage: boot-and-prep.sh <iso> [expected-port-count-per-router]
#   TOPO selects the topology, as for boot-topo.sh.
set -u

ISO=${1:?usage: boot-and-prep.sh <iso> [ports-per-router]}
WANT=${2:-2}
TOPO=${TOPO:-ipsec}
HERE=$(dirname "$0")

case "$TOPO" in
  bgp) ROUTERS="r1 r2 r3 r4"; HOSTS="231 232 233 234" ;;
  *)   ROUTERS="r1 r2 r3";    HOSTS="155 156 157" ;;
esac

echo "  booting TOPO=$TOPO"
TOPO="$TOPO" "$HERE/boot-topo.sh" "$ISO" >/dev/null 2>&1 || {
	echo "  FAILED: boot-topo.sh" >&2; exit 1; }

bad=0
for r in $ROUTERS; do
	if "$HERE/prep-router.sh" "/home/aikon/danos/.obs/run/$r/console.sock" >/dev/null 2>&1; then
		echo "  $r prepped"
	else
		echo "  FAILED: $r did not prepare" >&2
		bad=$((bad + 1))
	fi
done

# Prepared is not the same as wired. A router can take the console
# configuration and still be missing a port the topology depends on -- seen as
# "Cannot find device dp0s8" from a commit that then reported success.
for h in $HOSTS; do
	n=$(docker exec danos-robot timeout 10 sshpass -p vyatta ssh \
	      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	      -o ConnectTimeout=5 "vyatta@192.168.203.$h" \
	      'ip -br link show | grep -c "^dp0s"' 2>/dev/null | tr -dc '0-9')
	if [ -z "$n" ]; then
		echo "  FAILED: .$h is not reachable" >&2
		bad=$((bad + 1))
	elif [ "$n" -lt "$WANT" ]; then
		echo "  FAILED: .$h has $n dataplane ports, expected at least $WANT" >&2
		bad=$((bad + 1))
	else
		echo "  .$h  $n dataplane ports"
	fi
done

[ "$bad" -eq 0 ] || {
	echo "  $bad router(s) are not usable; refusing to run tests against this" >&2
	exit 1; }
echo "  topology ready"
