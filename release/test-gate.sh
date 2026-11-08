#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Gate a release on this project's own tests, before anything is built or
# signed. mk-release.py decides what a release CLAIMS about its provenance;
# each of those claims has a test here that fails when the claim stops being
# true. On 2026-11-07 the ancestry-only check reported 255 packages as
# unpublished for six days -- the kind of regression these tests exist to
# catch, and the reason they run before the pipeline instead of after it.
#
# Usage: test-gate.sh [--json <path>] [--quiet]
#   --json    write one machine-readable record of the result there
#   --quiet   only print the verdict line (for callers that log the rest)
#
# Exit: 0 all green, 1 something failed (always named), 2 bad usage.
#
# Run it from anywhere; it locates the toolkit from its own path. No network,
# no ISO, no container: release/test_mk_release.py uses throwaway git
# repositories and release/test_iso_pkgset.sh uses made-up dpkg status files.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
JSON=""
QUIET=0
while [ $# -gt 0 ]; do
	case "$1" in
		--json)  [ $# -ge 2 ] || { echo "usage: $0 [--json <path>] [--quiet]" >&2; exit 2; }
		         JSON=$2; shift 2 ;;
		--quiet) QUIET=1; shift ;;
		*) echo "usage: $0 [--json <path>] [--quiet]" >&2; exit 2 ;;
	esac
done

# pytest is not installed on every host this runs on (and must not be a
# precondition for a release), so the python half goes through stdlib
# unittest -- which is what CI-less runs actually have.
py_log=$(mktemp); sh_log=$(mktemp)
trap 'rm -f "$py_log" "$sh_log"' EXIT

tests=0; py_ok=0; sh_ok=0; failures=""

[ "$QUIET" = 1 ] || echo "== test gate: $ROOT =="

if [ "$QUIET" = 1 ]; then
	(cd "$ROOT" && python3 -m unittest discover -s release -p 'test_*.py') > "$py_log" 2>&1 && py_ok=1
else
	echo "-- python: unittest discover release/test_*.py --"
	(cd "$ROOT" && python3 -m unittest discover -s release -p 'test_*.py') > "$py_log" 2>&1 && py_ok=1
	grep -E '^(FAIL|ERROR): ' "$py_log" | sed 's/^/   /'
fi
ran=$(sed -n 's/^Ran \([0-9]\{1,\}\) tests\{0,1\} in .*/\1/p' "$py_log" | tail -1)
[ -n "${ran:-}" ] && tests=$ran
if [ "$py_ok" = 0 ]; then
	# unittest exits 1 for a failed assertion and 2 for a test that could not
	# even import; both are the gate's business, and the tail says which.
	failures="${failures}release/test_mk_release.py failed"
	[ "$QUIET" = 1 ] || { echo "   last lines of the failing run:"; tail -15 "$py_log" | sed 's/^/   /'; }
fi

if [ "$QUIET" = 1 ]; then
	/bin/bash "$HERE/test_iso_pkgset.sh" > "$sh_log" 2>&1 && sh_ok=1
else
	echo "-- shell: release/test_iso_pkgset.sh --"
	/bin/bash "$HERE/test_iso_pkgset.sh" > "$sh_log" 2>&1 && sh_ok=1
	grep -E '^FAIL ' "$sh_log" | sed 's/^/   /'
fi
if [ "$sh_ok" = 0 ]; then
	failures="${failures:+$failures; }release/test_iso_pkgset.sh failed"
	[ "$QUIET" = 1 ] || tail -10 "$sh_log" | sed 's/^/   /'
fi

head=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)
dirty=false
[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ] && dirty=true

ok=0
[ "$py_ok" = 1 ] && [ "$sh_ok" = 1 ] && ok=1

if [ -n "$JSON" ]; then
	python3 - "$JSON" "$ok" "$tests" "$py_ok" "$sh_ok" "$head" "$dirty" "$failures" <<'PYEOF'
import json, sys, datetime
path, ok, tests, py_ok, sh_ok, head, dirty, failures = sys.argv[1:9]
json.dump({
    "ok": ok == "1",
    "python_tests": int(tests or 0),
    "python_ok": py_ok == "1",
    "shell_ok": sh_ok == "1",
    "failures": [f for f in failures.split("; ") if f],
    "toolkit_head": head,
    "toolkit_dirty": dirty == "true",
    "ran_at": datetime.datetime.now(datetime.UTC).isoformat(timespec="seconds"),
}, open(path, "w"), indent=2)
PYEOF
	[ "$QUIET" = 1 ] || echo "   record: $JSON"
fi

# A dirty tree is reported, not fatal: the point of the gate is to know what
# the result describes. A release is assembled from a commit, and mk-release.py
# records the toolkit commit in build-inputs.json, so a dirty tree there has
# already been called out by the time this runs.
if [ "$ok" = 1 ]; then
	echo "TEST GATE OK ($tests python tests, iso-pkgset probes, toolkit $head${dirty:+, dirty=$dirty})"
	exit 0
fi
echo "TEST GATE FAILED -- ${failures}" >&2
exit 1
