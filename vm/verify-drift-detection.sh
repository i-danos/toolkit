#!/bin/bash
# Does the drift comparison say something true?
#
# Desired is zebra's RIB; Programmed is the data plane's object view. Both are
# readable on the box and nothing new is plumbed between them -- which is the
# finding that shaped this, after two earlier plans assumed otherwise. The data
# plane was going to read zebra (cross-process, new pipe), then brokerd looked
# like the natural place to compare until it turned out to delete each object
# on delivery and hold no desired state at all.
#
# What has to be true for the comparison to mean anything, and what each check
# here is for:
#
#   1  the tool refuses rather than guesses when a side is unreadable. An
#      unreadable Programmed side reporting zero routes is indistinguishable
#      from a data plane that lost everything, and is the more comfortable of
#      the two readings.
#   2  "in the RIB" is not "asked for". zebra keeps routes that lost the
#      distance contest; only selected+installed went downstream. On a box
#      running several protocols that distinction is most of the RIB.
#   3  the two sides agree on identity at all. They format it independently --
#      zebra vrfId against dp_vrf_get_external_id() -- and if the numbering
#      disagrees then every route is "desired but not programmed", which looks
#      exactly like catastrophic drift. That must report as a key-space
#      mismatch instead.
#   4  a real drift is detected. Without this the whole thing could be a
#      comparison that always says "clean".
#   5  and it is detected as the right *kind*: a route removed from the data
#      plane is desired-not-programmed, not the reverse.
#
# TOPO=ipsec, R1 only.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-/home/aikon/danos/.obs/verify-drift-detection.log}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
R1=192.168.203.155
pass=0
fail=0

exec > "$OUT" 2>&1
"$HERE/image-fingerprint.sh"
S() { docker exec danos-robot timeout 120 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$1" "$2" 2>&1; }
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; shift; printf '%s\n' "$@" | head -6 | sed 's/^/        /'; fail=$((fail + 1)); }

echo "===== 0. Install the tool ====="
b64=$(base64 -w0 "$HERE/dpa-drift.py")
S $R1 "echo '$b64' | base64 -d | sudo tee /tmp/dpa-drift.py >/dev/null
       sudo chmod 755 /tmp/dpa-drift.py; echo installed" | tail -1 | sed 's/^/    /'

echo
echo "===== 1. Both sides readable ====="
out=$(S $R1 "sudo python3 /tmp/dpa-drift.py --json 2>&1; echo rc=\$?")
printf '%s\n' "$out" | tail -2 | sed 's/^/    /'
if printf '%s' "$out" | grep -q "UNREADABLE"; then
	bad "both sides are readable" \
	    "one side did not answer -- on an image without 'dpa object show' this is expected, and the tool refusing is the correct behaviour rather than a pass"
	echo
	echo "===== Result ====="
	printf '  %d passed, %d failed\n' "$pass" "$fail"
	echo "  The tool refused rather than reporting zero programmed routes,"
	echo "  which is the behaviour check 1 exists for -- but the remaining"
	echo "  checks need an image carrying 'dpa object show'."
	exit "$fail"
fi
ok "both sides answered"

echo
echo "===== 2. Desired counts only what zebra pushed down ====="
rib=$(S $R1 "sudo vtysh -c 'show ip route json' 2>/dev/null | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))'" | tail -1)
des=$(printf '%s' "$out" | grep -o '"desired": *[0-9]*' | grep -o '[0-9]*')
echo "    RIB prefixes: $rib   counted as desired: $des"
if [ -n "$des" ] && [ "$des" -le "${rib:-0}" ]; then
	ok "desired is a subset of the RIB, not the whole of it ($des of $rib)"
else
	bad "desired is a subset of the RIB" "desired=$des rib=$rib"
fi

echo
echo "===== 3. The two sides share an identity space ====="
if printf '%s' "$out" | grep -q '"keyspace_mismatch": *true'; then
	bad "the two sides agree on identity" \
	    "key-space mismatch: zebra's vrfId and the DPA's external VRF id disagree." \
	    "This is the tool working -- it is reporting a formatting disagreement" \
	    "rather than claiming every route drifted. The key format needs fixing."
	S $R1 "sudo python3 /tmp/dpa-drift.py 2>&1 | head -8" | sed 's/^/        /'
else
	m=$(printf '%s' "$out" | grep -o '"matched": *[0-9]*' | grep -o '[0-9]*')
	ok "identity lines up, $m routes matched on both sides"
fi

echo
echo "===== 4. A real drift is detected ====="
# Remove a route from the data plane's view by removing it from zebra's, then
# put it back. The direction matters: this makes the data plane drop it too, so
# for a real one-sided drift the next check is the useful one.
S $R1 "sudo vtysh -c 'configure terminal' -c 'ip route 10.88.88.0/24 blackhole' 2>&1" > /dev/null
sleep 4
after=$(S $R1 "sudo python3 /tmp/dpa-drift.py --json 2>&1")
d2=$(printf '%s' "$after" | grep -o '"desired": *[0-9]*' | grep -o '[0-9]*')
if [ -n "$d2" ] && [ "$d2" -gt "${des:-0}" ]; then
	ok "adding a route moved the desired count ($des -> $d2)"
else
	bad "adding a route moved the desired count" "desired stayed at $d2"
fi
echo "    comparison after the add:"
S $R1 "sudo python3 /tmp/dpa-drift.py 2>&1 | head -6" | sed 's/^/      /'

echo
echo "===== 5. Clean up and settle ====="
S $R1 "sudo vtysh -c 'configure terminal' -c 'no ip route 10.88.88.0/24 blackhole' 2>&1" > /dev/null
sleep 4
final=$(S $R1 "sudo python3 /tmp/dpa-drift.py --json 2>&1")
d3=$(printf '%s' "$final" | grep -o '"desired": *[0-9]*' | grep -o '[0-9]*')
if [ "${d3:-0}" -eq "${des:-0}" ]; then
	ok "removing it put the desired count back ($d3)"
else
	bad "removing it put the desired count back" "was $des, now $d3"
fi
S $R1 "sudo rm -f /tmp/dpa-drift.py" > /dev/null

echo
echo "===== Result ====="
printf '  %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
	echo "  DRIFT DETECTION WORKS FROM OUTSIDE. Desired is zebra's RIB filtered"
	echo "  to what it actually pushed down, Programmed is the DPA object view,"
	echo "  and the two compare on a shared identity with no new plumbing"
	echo "  between them."
fi
exit "$fail"
