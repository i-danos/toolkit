#!/bin/bash
# Which repositories have commits that are not on OBS?
#
# git push and an OBS upload are separate acts, and nothing links them. Missing
# the second is easy and the symptom is bad: the source is right, the git
# history is right, the OBS build succeeds -- of the previous source -- and the
# image carries code that does not match the tree it was supposedly built from.
#
# It cost a whole end-to-end run here. vyatta-dataplane's 802.1X state model was
# corrected, committed and pushed, but not uploaded, so the image shipped the
# earlier two-state build. The component called "dot1x enable", a command that
# build does not have, and from the component's side everything looked fine:
# hostapd started, its configuration was written, the pid files were there.
#
# The check compares the .dsc that HEAD would produce against the one on OBS.
# Generating a .dsc per repository is slow, so this compares md5 only for the
# packages already staged in dsc/, and otherwise reports whether the repository
# has moved since that .dsc was written.
set -u

OBS=${OBS_DIR:-/home/aikon/danos/.obs}
# setsid: no controlling terminal, so an expired osc session fails fast instead
# of blocking on a /dev/tty password prompt that SIGTTIN then stops. See the
# long note in upload.sh.
OSC="setsid --wait $OBS/osc -A https://api.opensuse.org"
SRC=/home/aikon/danos/build-iso/danos-sources
PRJ=home:i-danos

# Probe authentication before reporting anything.
#
# An unauthenticated API call fails, the md5 comes back empty, and the loop
# below reads that as "not on OBS" -- for every package, including the 150 that
# are up there and building. The run looks like a catastrophic finding rather
# than an expired cookie. A check that answers confidently when it cannot see
# anything is worse than one that refuses to run.
if ! timeout 30 $OSC api "/source/$PRJ" < /dev/null > /dev/null 2>&1; then
	echo "Cannot reach $PRJ: the osc session has expired." >&2
	echo "Without it every package would be reported as \"not on OBS\", so this" >&2
	echo "check refuses to run. Refresh the session yourself:" >&2
	echo >&2
	echo "    $OBS/osc -A https://api.opensuse.org api /person/i-danos > /dev/null && echo OK" >&2
	exit 1
fi

printf '  %-34s %-12s %s\n' REPOSITORY DSC STATUS
for d in "$SRC"/*/; do
	r=$(basename "$d")
	[ -d "$d/.git" ] || continue

	# The source package name is not always the directory name --
	# vyatta-cfg-dataplane produces vplane-config -- so take it from
	# debian/control rather than assuming.
	[ -f "$d/debian/control" ] || continue
	p=$(awk '/^Source:/{print $2; exit}' "$d/debian/control")
	[ -n "$p" ] || continue

	dsc=$(ls "$OBS/dsc/${p}_"*.dsc 2>/dev/null | sed "s|.*/${p}_||; s|\.dsc$||" \
	      | sort -V | tail -1)
	[ -n "$dsc" ] || continue

	local_md5=$(md5sum "$OBS/dsc/${p}_${dsc}.dsc" | cut -d' ' -f1)
	remote_md5=$(timeout 60 $OSC api "/source/$PRJ/$p" < /dev/null 2>/dev/null \
	  | awk -v n="${p}_${dsc}.dsc" 'match($0, /<entry name="[^"]*" md5="[^"]*"/) {
	      e = substr($0, RSTART, RLENGTH); split(e, a, "\"")
	      if (a[2] == n) print a[4] }' | head -1)

	# Has the repository moved since the .dsc was made? Compare the commit
	# mk-dsc.sh recorded, not timestamps: a mtime comparison answers yes for
	# every commit that never reached a .dsc -- a .gitignore line, a comment
	# -- and named 19 repositories on its first run here, which is a check
	# nobody would read twice.
	#
	# A .dsc with no recorded commit predates that, and is reported as
	# unknown rather than silently assumed current.
	head=$(cd "$d" && git rev-parse HEAD 2>/dev/null)
	made=""
	[ -f "$OBS/dsc/${p}_${dsc}.commit" ] && made=$(cat "$OBS/dsc/${p}_${dsc}.commit")

	status=""
	if [ -z "$remote_md5" ]; then
		status="not on OBS"
	elif [ "$remote_md5" != "$local_md5" ]; then
		status="dsc/ differs from OBS -- upload"
	elif [ -z "$made" ]; then
		status="unknown: .dsc predates commit recording -- regenerate to find out"
	elif [ "$made" != "$head" ]; then
		status="HEAD $(echo "$head" | cut -c1-8) != .dsc $(echo "$made" | cut -c1-8) -- regenerate and upload"
	fi
	[ -n "$status" ] && printf '  %-34s %-12s %s\n' "$p" "$dsc" "$status"
done
echo "  --- repositories not listed are current ---"
