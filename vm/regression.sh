#!/bin/bash
# The five DANOS Robot suites, 74 cases, against one image.
#
# This has been run after every change here and reconstructed by hand every
# time, which is how two of this project's worst readings happened: a full run
# against the *previous* ISO, because the new build had failed and `ls -t` still
# found an image; and suites that carried on after a router failed to prepare,
# reporting fw 0/16 and bgp 1/15 -- which read as two broken features rather
# than one unprepared router.
#
# So the gates are part of the run, not part of whoever remembers them:
#
#   - the image must exist and be named on the command line, never discovered
#   - boot-and-prep.sh must pass before any suite in that group runs
#   - each suite's case count is asserted, not just its failure count
#
# That last one is the subtle gate. A suite that never ran reports zero
# failures, and zero failures summed with four other zeroes is indistinguishable
# from a clean run. The counts below are what these five suites contain, so a
# suite that produces fewer has not passed -- it has gone missing.
#
# Usage: regression.sh <iso> [tag]
#   tag names the results directories, default "reg".
set -u

ISO=${1:?usage: regression.sh <iso> [tag]}
TAG=${2:-reg}
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPTS=/tests/Test_Automation/script
RESULTS=/tests/Test_Automation

[ -f "$ISO" ] || { echo "no such image: $ISO" >&2; exit 1; }

# suite-key  topology  robot-file            expected cases
SUITES="
ipsec ipsec IPSEC_VPN_DANOS  10
mpls  ipsec MPLS_LDP_DANOS   11
fw    fw    FIREWALL_DANOS   16
bgp   bgp   BGP_DANOS        16
rest  bgp   danos_restapi    21
"

total_pass=0
total_fail=0
bad=0
summary=""

run_suite() {
	local key=$1 file=$2 want=$3
	local out line p f
	out=$(docker exec danos-robot robot -d "$RESULTS/results-$TAG-$key" \
	        "$SCRIPTS/$file.robot" 2>&1)
	# Robot's own summary line, e.g. "10 tests, 10 passed, 0 failed, 0 skipped."
	line=$(printf '%s' "$out" | grep -E '^[0-9]+ tests?, [0-9]+ passed, [0-9]+ failed' | tail -1)
	if [ -z "$line" ]; then
		printf '  %-6s DID NOT REPORT -- the run produced no summary line\n' "$key"
		printf '%s\n' "$out" | tail -8 | sed 's/^/         /'
		bad=$((bad + 1))
		return
	fi
	p=$(printf '%s' "$line" | sed -E 's/.*, ([0-9]+) passed.*/\1/')
	f=$(printf '%s' "$line" | sed -E 's/.*, ([0-9]+) failed.*/\1/')
	total_pass=$((total_pass + p))
	total_fail=$((total_fail + f))
	printf '  %-6s pass=%s fail=%s\n' "$key" "$p" "$f"
	[ "$f" -eq 0 ] || bad=$((bad + 1))
	if [ $((p + f)) -ne "$want" ]; then
		printf '  %-6s RAN %s CASES, EXPECTED %s -- cases went missing, not passed\n' \
		       "$key" "$((p + f))" "$want"
		bad=$((bad + 1))
	fi
	summary="$summary  $key pass=$p fail=$f"$'\n'
}

for topo in ipsec fw bgp; do
	echo "=== regression $topo ==="
	if ! TOPO="$topo" "$HERE/boot-and-prep.sh" "$ISO"; then
		echo "  the topology is not usable; every suite in this group is skipped"
		echo "  rather than run against it -- a suite that fails for this reason"
		echo "  reads as a product defect." >&2
		bad=$((bad + 1))
		continue
	fi
	# Not "printf ... | while read": a while loop on the right of a pipe runs
	# in a subshell, so every bad++ inside it is discarded when the subshell
	# exits. The first version of this file did exactly that, counted 22
	# failures, lost all of them, and printed "74 of 74".
	while read -r key t file want; do
		[ -n "${key:-}" ] || continue
		[ "$t" = "$topo" ] || continue
		run_suite "$key" "$file" "$want"
	done <<-EOF
	$SUITES
	EOF
done

# The verdict comes from the results on disk, not from the counters above:
# output.xml is what each suite recorded, while the lines above are what its
# stdout said. They should agree, and when they do not the file is right.
echo
echo "=== totals ==="
# "docker exec -i". Without it the heredoc never reaches python, which then
# reads an empty program from a closed stdin, prints nothing, and exits 0 -- a
# totals check that cannot fail, in the file whose whole purpose is to stop
# checks that cannot fail. It shipped that way once and reported "74 of 74" for
# a run that was 52 of 74. The VERDICT line below is the guard against it
# happening again in some new form: if python did not run, there is no verdict,
# and no verdict is a failure rather than a pass.
verdict=$(docker exec -i danos-robot python3 - "$TAG" <<'PY'
import glob
import sys
import xml.etree.ElementTree as ET

tag = sys.argv[1]
want = {"ipsec": 10, "mpls": 11, "fw": 16, "bgp": 16, "rest": 21}
tp = tf = 0
bad = 0
for key, n in want.items():
    paths = glob.glob("/tests/Test_Automation/results-%s-%s/output.xml" % (tag, key))
    if not paths:
        print("  %-6s NO RESULTS -- the suite did not run" % key)
        bad += 1
        continue
    stat = ET.parse(paths[0]).getroot().find("statistics/total/stat")
    p, f = int(stat.get("pass")), int(stat.get("fail"))
    tp += p
    tf += f
    flag = ""
    if f:
        flag = "  <-- failures"
        bad += 1
    if p + f != n:
        flag = "  <-- ran %d of %d cases" % (p + f, n)
        bad += 1
    print("  %-6s pass=%-3d fail=%-3d%s" % (key, p, f, flag))
print("  %-6s pass=%-3d fail=%-3d  of 74 expected" % ("TOTAL", tp, tf))
print("VERDICT %s %d %d" % ("CLEAN" if not (bad or tp != 74 or tf) else "DIRTY", tp, tf))
PY
)
printf '%s\n' "$verdict" | grep -v '^VERDICT '
line=$(printf '%s\n' "$verdict" | grep '^VERDICT ' | tail -1)
if [ -z "$line" ]; then
	echo "  NO VERDICT -- the totals check produced nothing, so this run is"
	echo "  unjudged. Treat it as a failure: an absent check is the one thing"
	echo "  that looks exactly like a passing one." >&2
	exit 1
fi
set -- $line
if [ "$2" != "CLEAN" ] || [ "$bad" -ne 0 ]; then
	printf '  REGRESSION NOT CLEAN: %s passed, %s failed of 74\n' "$3" "$4"
	exit 1
fi
echo "  74 of 74"
