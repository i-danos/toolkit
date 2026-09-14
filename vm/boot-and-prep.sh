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

ISO=${1:?usage: boot-and-prep.sh <iso>}
TOPO=${TOPO:-ipsec}
HERE=$(dirname "$0")

# The ports each router must end up with, by name, exactly as boot-topo.sh
# wires them and exactly as the suites configure them. WANTED is one
# "<host>:<port> <port> ..." entry per router.
#
# Names, not a count, and not a floor. The floor is what let a BGP run through
# with r2 holding two ports where the topology gives it three -- ".232 2
# dataplane ports" printed as if it were fine, because two is at least two. A
# count alone is barely better: a router that came up with dp0s3 and dp0s9
# where the suite configures dp0s9 and dp0s10 has the right number of the wrong
# ports, and the suite then fails on "Cannot find device dp0s10" in the middle
# of a test that reads as a protocol failure.
case "$TOPO" in
  fw)  ROUTERS="r1 r2 r3"
       WANTED="155:dp0s8 dp0s9|156:dp0s9 dp0s10|157:dp0s9 dp0s10"
       RELAYS="r1:192.168.203.155:2231 r2:192.168.203.156:2232
               r3:192.168.203.157:2233" ;;
  bgp) ROUTERS="r1 r2 r3 r4"
       WANTED="231:dp0s3 dp0s9|232:dp0s3 dp0s9 dp0s10|233:dp0s3 dp0s9|234:dp0s3 dp0s9 dp0s10"
       RELAYS="r1:192.168.203.231:2231 r2:192.168.203.232:2232
               r3:192.168.203.233:2233 r4:192.168.203.234:2234" ;;
  *)   ROUTERS="r1 r2 r3"
       WANTED="155:dp0s3 dp0s9|156:dp0s3 dp0s8|157:dp0s3 dp0s8"
       RELAYS="r1:192.168.203.155:2231 r2:192.168.203.156:2232
               r3:192.168.203.157:2233" ;;
esac

# The relays are per-topology too, and they do not come down with the VMs.
#
# The two topologies use different management addresses -- .155-.157 for the
# three-router suites, .231-.234 for BGP -- and each relay is a container
# holding one of them. Boot the ipsec topology after a BGP run and the VMs are
# fine while every relay is still answering on the BGP addresses, so all three
# routers are unreachable at the addresses this run uses. That is what happened
# here: three "prepped" lines followed by three "not reachable" ones, from a
# boot that was entirely successful.
#
# Rebuilding them is a few seconds and removes the whole class, so it is not
# conditional on what is already running.
echo "  relays for TOPO=$TOPO"
"$HERE/relays.sh" down >/dev/null 2>&1
# shellcheck disable=SC2086  # deliberate word splitting: one spec per relay
"$HERE/relays.sh" up $RELAYS >/dev/null 2>&1 || {
	echo "  FAILED: relays did not come up" >&2; exit 1; }

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
ports_of() {
	docker exec danos-robot timeout 15 sshpass -p vyatta ssh \
	  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	  -o ConnectTimeout=5 "vyatta@192.168.203.$1" \
	  'ip -br link show | awk "/^dp0s/ {print \$1}" | sort' 2>/dev/null \
	  | tr -d '\r' | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//'
}

# A port can still be arriving: the dataplane claims NICs as it starts, and the
# prep loop above returns as soon as the console is usable. Poll rather than
# judge on the first read, so a slow claim is a wait and not a failure -- while
# a port that is genuinely absent still fails, just sixty seconds later.
#
# A port can still be arriving: the dataplane claims NICs as it starts, and the
# prep loop above returns as soon as the console is usable. So poll rather than
# judge on the first read -- a slow claim becomes a wait, while a port that is
# genuinely absent still fails, just a minute later.
#
# The loop runs in this shell, not a pipeline, so that "bad" survives it. A
# "while read" on the right of a pipe runs in a subshell and its counter goes
# out of scope with it, leaving a gate that counts every failure and then
# reports none.
OLDIFS=$IFS
IFS='|'
for entry in $WANTED; do
	IFS=$OLDIFS
	[ -n "$entry" ] || continue
	h=${entry%%:*}
	want=$(printf '%s' "${entry#*:}" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')
	got=""
	for _ in $(seq 1 12); do
		got=$(ports_of "$h")
		[ "$got" = "$want" ] && break
		sleep 5
	done
	if [ -z "$got" ]; then
		echo "  FAILED: .$h is not reachable" >&2
		bad=$((bad + 1))
	elif [ "$got" != "$want" ]; then
		echo "  FAILED: .$h has [$got], the topology wires [$want]" >&2
		bad=$((bad + 1))
	else
		echo "  .$h  $got"
	fi
	IFS='|'
done
IFS=$OLDIFS

# Finally: are these VMs even running the image this call was given?
#
# Everything above can pass on the previous topology's VMs. The port-name check
# separates fw from ipsec, but not this image from the last one, and a booted
# router answers ssh identically either way. So the last gate reads the ISO out
# of each qemu's own command line and compares it with the one asked for.
#
# This is the check that would have caught the run where a dataplane fix was
# measured as ineffective: the VMs answering were still booted from the image
# from before the fix.
"$HERE/image-fingerprint.sh" --assert "$ISO" || bad=$((bad + 1))

[ "$bad" -eq 0 ] || {
	echo "  $bad router(s) are not usable; refusing to run tests against this" >&2
	exit 1; }
echo "  topology ready"
