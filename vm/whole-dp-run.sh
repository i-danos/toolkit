#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-only
# Run every registered vyatta-dataplane whole_dp unit-test suite, one at a time, and record each result.
#
# Why this exists: vyatta-dataplane/debian/rules has an EMPTY `override_dh_auto_test:`, so the package build compiles the 22.8 kLOC data
# plane's test binaries and never runs them, and nothing else did either. Running them by hand has four traps, all of which cost a
# wrong "passed" or a wrong "failed" the first time:
#   - dataplane_test refuses to run as root ("Please run as normal user, not root");
#   - `meson test --no-rebuild` skips the `dummyfs` dependency, so the test FAL plugins are never configured;
#   - a case selector that matches nothing (CK_RUN_CASE=<name>) exits 0 with "Checks: 0";
#   - there is no way to run one case by name: every test of a file shares one check case name.
# This script builds in a throwaway debian container (the host has no meson/ninja/DPDK headers), runs as an ordinary user inside it, builds
# dummyfs, asks meson which suites exist, and runs them serially. "Did not run" is never recorded as "passed".
#
# Usage: whole-dp-run.sh --out DIR [--src REPO] [--work DIR] [--only a.c,b.c] [--resume] [--rebuild]
#   --out DIR     results: results.jsonl (one line per suite), registered.txt, env.txt, logs/ (raw output per suite)
#   --src REPO    git repository of the data plane (default: the toolkit's sibling vyatta-dataplane); HEAD is exported with `git archive`,
#                 so the working tree is neither read nor modified and uncommitted changes are NOT tested (the dirty flag is recorded)
#   --work DIR    persistent build tree (default $OBS_DIR/whole-dp-work, i.e. outside every repository). A finished build is reused only if
#                 it is of the same commit; otherwise the tree is rebuilt from scratch.
#   --runtime-debs DIR  before testing, `dpkg -i --force-depends --force-downgrade DIR/librte-*.deb` in the container: run the same binary on another
#                 DPDK runtime (the A/B for "is the DPDK version the cause")
#   --all-tests   configure with meson -Dall_tests=true (229 DP_START_TEST_FULL_RUN tests compiled in, 600 s timeout); uses its own work dir
#   --only LIST   comma separated suite names;  --repeat N run each selected suite N times (a suite whose iterations disagree is reported "mixed");  --resume skip suites already in results.jsonl;  --rebuild force a fresh build
# Then:  whole-dp-report.py DIR   (summary.json, summary.tsv, report.md; triage labels are merged from DIR/triage.json if present)
# Env:  DEBIAN_MIRROR / DEBIAN_SECURITY_MIRROR as in build-iso-container.sh (auto: Aliyun when deb.debian.org does not resolve)
# Needs: docker, direct network (no proxy) to the DANOS apt repository for Build-Depends, >= MIN_MEM_MB available memory (default 4096).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/../.." && pwd)/vyatta-dataplane
OBS=${OBS_DIR:-/home/aikon/danos/.obs}
WORK=$OBS/whole-dp-work
OUT=""; ONLY=""; RESUME=0; REBUILD=0; REPEAT=1; RUNTIME_DEBS=""; ALL_TESTS=0
IMAGE=${IMAGE:-debian:13-slim}
MIN_MEM_MB=${MIN_MEM_MB:-4096}
APT_URL=${APT_URL:-https://r2.aikon.qzz.io/danos-apt/test/}
LOCAL_REPO=${LOCAL_REPO:-/home/aikon/danos/build-iso/danos-build/local-repo}
DEBIAN_MIRROR=${DEBIAN_MIRROR:-}
DEBIAN_SECURITY_MIRROR=${DEBIAN_SECURITY_MIRROR:-}

while [ $# -gt 0 ]; do
	case "$1" in
		--out) OUT=$2; shift 2 ;;
		--src) SRC=$2; shift 2 ;;
		--work) WORK=$2; shift 2 ;;
		--only) ONLY=$2; shift 2 ;;
		--resume) RESUME=1; shift ;;
		--repeat) REPEAT=$2; shift 2 ;;
		--runtime-debs) RUNTIME_DEBS=$2; shift 2 ;;
		--all-tests) ALL_TESTS=1; shift ;;
		--rebuild) REBUILD=1; shift ;;
		-h|--help) sed -n 2,28p "$0"; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done
[ "$ALL_TESTS" = 1 ] && [ "$WORK" = "$OBS/whole-dp-work" ] && WORK=$OBS/whole-dp-work-alltests   # never mix the two configurations in one build tree
[ -n "$OUT" ] || { echo "usage: $0 --out DIR [options]  (see --help)" >&2; exit 2; }
[ -d "$SRC/.git" ] || { echo "not a git repository: $SRC" >&2; exit 2; }
command -v docker >/dev/null || { echo "docker not found" >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo "docker daemon not reachable" >&2; exit 2; }

mem=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
if [ "$mem" -lt "$MIN_MEM_MB" ]; then
	echo "PREFLIGHT FAILED: MemAvailable ${mem} MB < ${MIN_MEM_MB} MB (the build links with LTO). Free memory; this script does not add swap." >&2
	exit 1
fi

COMMIT=$(git -C "$SRC" rev-parse HEAD)
DIRTY=$(git -C "$SRC" status --porcelain --untracked-files=no | wc -l)
mkdir -p "$OUT" "$WORK"
OUT=$(cd "$OUT" && pwd); WORK=$(cd "$WORK" && pwd)

if [ "$REBUILD" = 1 ] || [ "$(cat "$WORK/commit" 2>/dev/null)" != "$COMMIT" ] || [ ! -f "$WORK/build.ok" ]; then
	echo "exporting $COMMIT (tracked files of HEAD only) into $WORK/src"
	# files written by the container are chowned back to the invoking uid, so a plain rm works; if it does not, say so and stop
	rm -rf "$WORK/src" "$WORK/build.ok" "$WORK/commit" 2>/dev/null
	[ ! -e "$WORK/src" ] || { echo "cannot remove $WORK/src (root-owned leftovers from an interrupted run?)" >&2; exit 1; }
	mkdir -p "$WORK/src"
	git -C "$SRC" archive HEAD | tar -x -C "$WORK/src"
	echo "$COMMIT" > "$WORK/commit"
else
	echo "reusing the finished build of $COMMIT in $WORK"
fi
echo "$COMMIT dirty_tracked_files=$DIRTY" > "$OUT/source.txt"

if [ -z "$DEBIAN_MIRROR" ] && ! getent hosts deb.debian.org >/dev/null 2>&1; then
	DEBIAN_MIRROR=http://mirrors.aliyun.com/debian/; DEBIAN_SECURITY_MIRROR=http://mirrors.aliyun.com/debian-security/
	echo "NOTE: deb.debian.org does not resolve here; using $DEBIAN_MIRROR (the project's own build mirror). The mirror can lag Debian: the DPDK version actually used is in env.txt." | tee -a "$OUT/run.txt"
fi
echo "start $(date -u +%FT%TZ)  MemAvailable=${mem} MB  load=$(cut -d' ' -f1-3 /proc/loadavg)" | tee "$OUT/run.txt"
repo_args=()
ls "$LOCAL_REPO"/*.deb >/dev/null 2>&1 && repo_args=(--volume "$LOCAL_REPO:/repo:ro")
[ -n "$RUNTIME_DEBS" ] && repo_args+=(--volume "$(cd "$RUNTIME_DEBS" && pwd):/runtime-debs:ro")
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
docker run --rm --network host \
	--env APT_URL="$APT_URL" --env DEBIAN_MIRROR="$DEBIAN_MIRROR" --env DEBIAN_SECURITY_MIRROR="$DEBIAN_SECURITY_MIRROR" --env ONLY="$ONLY" --env RESUME="$RESUME" --env REPEAT="$REPEAT" --env ALL_TESTS="$ALL_TESTS" --env SUITE_TIMEOUT="${SUITE_TIMEOUT:-1800}" \
	--volume "$WORK:/work" --volume "$OUT:/out" --volume "$HERE:/toolkit:ro" "${repo_args[@]}" \
	"$IMAGE" bash /toolkit/whole-dp-inner.sh 2>&1 | tee "$OUT/run.log"
rc=${PIPESTATUS[0]}
echo "end $(date -u +%FT%TZ)  container rc=$rc  MemAvailable=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo) MB  load=$(cut -d' ' -f1-3 /proc/loadavg)" | tee -a "$OUT/run.txt"
[ $rc -eq 0 ] && python3 "$HERE/whole-dp-report.py" "$OUT" >/dev/null 2>&1
exit $rc
