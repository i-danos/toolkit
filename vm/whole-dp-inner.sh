#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-only
# Runs INSIDE the container started by whole-dp-run.sh. Not meant to be run by hand.
#
# Mounts: /work (persistent build tree, /work/src = git export of the data plane), /out (results), /repo (optional local debs, ro).
# Env:    APT_URL  DANOS apt repository for Build-Depends;  ONLY  comma separated suite names (default: every registered suite)
#         RESUME=1 skip suites already present in /out/results.jsonl;  REPEAT=N run each selected suite N times (one JSON line each, "iter" says which);  SUITE_TIMEOUT  hard cap per suite in seconds
#
# What it does, in order:
#   1. install the Build-Depends with mk-build-deps (as root);
#   2. build the tree the way the package does (`debian/rules build`, as an ordinary user: dataplane_test refuses root) unless /work
#      already holds a finished build of the same commit (/work/build.ok);
#   3. build the `dummyfs` target (a meson `depends:` of every test; `--no-rebuild` skips it, and without it the test FAL plugins are
#      never configured and suites fail for a reason that is not the product);
#   4. ask meson which suites are registered (`meson test --list`) and run them ONE AT A TIME, writing one JSON line per suite.
# A suite that cannot be classified is recorded with what was seen; nothing here turns "did not run" into "passed".
set -u
: "${APT_URL:=https://r2.aikon.qzz.io/danos-apt/test/}"
: "${SUITE_TIMEOUT:=1800}"
: "${ONLY:=}"
: "${RESUME:=0}"
: "${REPEAT:=1}"
: "${ALL_TESTS:=0}"
: "${DEBIAN_MIRROR:=}"
: "${DEBIAN_SECURITY_MIRROR:=}"
export DEBIAN_FRONTEND=noninteractive
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
trap 'chown -R tester /work /out 2>/dev/null || true' EXIT

mkdir -p /out/logs
if [ ! -f /work/deps.ok ]; then
	log "installing build dependencies (apt output: logs/_apt.log)"
	: > /out/logs/_apt.log
	# Same knobs as build-iso-container.sh. The slim image's sources are deb822 files naming deb.debian.org.
	if [ -n "$DEBIAN_MIRROR" ]; then
		sed -i "s|http://deb.debian.org/debian-security|${DEBIAN_SECURITY_MIRROR:-${DEBIAN_MIRROR%/}-security}|; s|http://deb.debian.org/debian|${DEBIAN_MIRROR%/}|" /etc/apt/sources.list.d/debian.sources 2>/dev/null
		log "Debian mirror: ${DEBIAN_MIRROR}"
	fi
	apt_fail() { log "FATAL $1 -- last lines of logs/_apt.log:"; grep -E '^(E|W):' /out/logs/_apt.log | sort -u | head -6; exit 2; }
	apt-get update -q >>/out/logs/_apt.log 2>&1
	apt-get install -y -q --no-install-recommends ca-certificates >>/out/logs/_apt.log 2>&1 || apt_fail "apt could not install ca-certificates (no usable package index: network or DNS?)"
	echo "deb [trusted=yes] ${APT_URL%/}/ ./" > /etc/apt/sources.list.d/danos.list
	echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80retries
	if ls /repo/*.deb >/dev/null 2>&1; then echo "deb [trusted=yes] file:/repo ./" > /etc/apt/sources.list.d/local.list; fi
	apt-get update -q >>/out/logs/_apt.log 2>&1
	apt-get install -y -q --no-install-recommends build-essential fakeroot devscripts equivs >>/out/logs/_apt.log 2>&1 || apt_fail "apt install of the build tools failed"
	( cd /work/src && mk-build-deps -i -r -t "apt-get -y -q --no-install-recommends" debian/control >/out/logs/_build-deps.log 2>&1 ) \
		|| { log "FATAL mk-build-deps failed, see logs/_build-deps.log"; exit 2; }
	# deps live in this container only; the container is thrown away, so there is no marker to trust
fi
id tester >/dev/null 2>&1 || useradd -m tester
chown -R tester /work /out

if [ ! -f /work/build.ok ]; then
	log "building the data plane and its test binaries (debian/rules build)"
	runuser -u tester -- bash -c 'cd /work/src && debian/rules build' >/out/logs/_build.log 2>&1
	rc=$?
	[ $rc -eq 0 ] || { log "FATAL build failed rc=$rc, see logs/_build.log"; tail -15 /out/logs/_build.log; exit 3; }
	if [ "$ALL_TESTS" = 1 ]; then
		# meson option all_tests: compiles the DP_START_TEST_FULL_RUN tests in and raises the per-suite timeout from 120 to 600 s
		log "reconfiguring with -Dall_tests=true and rebuilding"
		runuser -u tester -- bash -c 'cd /work/src && meson configure build -Dall_tests=true && ninja -C build' >/out/logs/_build-alltests.log 2>&1 \
			|| { log "FATAL all_tests rebuild failed, see logs/_build-alltests.log"; tail -8 /out/logs/_build-alltests.log; exit 3; }
	fi
	touch /work/build.ok
else
	log "reusing the finished build in /work/src/build"
fi
B=/work/src/build
[ -d $B ] || { log "FATAL no build directory $B"; exit 3; }

runuser -u tester -- bash -c "cd /work/src && ninja -C build tests/whole_dp/dummyfs" >/out/logs/_dummyfs.log 2>&1 \
	|| { log "FATAL dummyfs target failed"; tail -5 /out/logs/_dummyfs.log; exit 3; }

# Optional A/B: replace the installed DPDK runtime libraries by another set of .debs (the test binary was built against the headers
# of whatever the mirror shipped; the DPDK 24.11 stable series keeps its ABI, so the same binary runs on both).
if [ -d /runtime-debs ]; then
	log "replacing the DPDK runtime with $(ls /runtime-debs/librte-*.deb | wc -l) debs from /runtime-debs"
	dpkg -i --force-depends --force-downgrade /runtime-debs/librte-*.deb >/out/logs/_runtime-debs.log 2>&1 \
		|| { log "FATAL dpkg -i of the runtime debs failed, see logs/_runtime-debs.log"; tail -5 /out/logs/_runtime-debs.log; exit 3; }
fi
{
	echo "date_utc=$(date -u +%FT%TZ)"
	[ -d /runtime-debs ] && echo "runtime_debs=replaced from /runtime-debs"
	echo "all_tests=$ALL_TESTS"
	echo "commit=$(cat /work/commit 2>/dev/null)"
	echo "image=$(. /etc/os-release; echo "$PRETTY_NAME")"
	echo "kernel=$(uname -r)"
	echo "cpus=$(nproc)"
	echo "meson=$(meson --version)"
	for p in libdpdk-dev librte-eal25 libcheck-dev; do echo "pkg:$p=$(dpkg-query -W -f='${Version}' $p 2>/dev/null)"; done
} > /out/env.txt

# The registered suites, as meson sees them. This is the authority for "how many suites exist", not a grep of the build file.
runuser -u tester -- bash -c "cd /work/src && meson test -C build --list" 2>/dev/null | sed 's/^.* \/ //' | grep -E '^dp_test_.*\.c$' | sort -u > /out/registered.txt
n=$(wc -l < /out/registered.txt)
log "meson registers $n suites"
[ "$n" -gt 0 ] || { log "FATAL meson --list gave no suites"; exit 3; }

if [ -n "$ONLY" ]; then tr ',' '\n' <<<"$ONLY" > /out/_only.txt; else cp /out/registered.txt /out/_only.txt; fi

touch /out/results.jsonl
total=$(wc -l < /out/_only.txt); i=0
while read -r s; do
	[ -n "$s" ] || continue
	i=$((i+1))
	if [ "$RESUME" = 1 ] && grep -q "\"suite\":\"$s\"" /out/results.jsonl; then log "[$i/$total] $s already recorded, skipped (--resume)"; continue; fi
	for it in $(seq 1 "$REPEAT"); do
		lg=$s; [ "$REPEAT" -gt 1 ] && lg=$s.iter$it
		rm -f "$B/tests/whole_dp/test_$s.xml"
		mem0=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo); load0=$(cut -d' ' -f1 /proc/loadavg)
		t0=$(date +%s.%N)
		timeout "$SUITE_TIMEOUT" runuser -u tester -- bash -c "cd /work/src && meson test -C build --no-rebuild --print-errorlogs '$s'" > "/out/logs/$lg.log" 2>&1
		rc=$?
		t1=$(date +%s.%N)
		mem1=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo); load1=$(cut -d' ' -f1 /proc/loadavg)
		secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')
		x="$B/tests/whole_dp/test_$s.xml"
		if [ -f "$x" ]; then
			cp "$x" "/out/logs/$lg.check.xml"
			nt=$(grep -c '<test result=' "$x"); nf=$(grep -c '<test result="failure"' "$x"); ne=$(grep -c '<test result="error"' "$x"); hasxml=true
		else nt=0; nf=0; ne=0; hasxml=false; fi
		g() { awk -v k="$1" '$1==k":"{print $2; f=1} END{if(!f) print 0}' "/out/logs/$lg.log"; }
		ok=$(g Ok); fail=$(g Fail); skipped=$(g Skipped); tmo=$(g Timeout); xfail=$(g "Expected Fail"); upass=$(g "Unexpected Pass")
		checks0=$(grep -c 'Checks: 0, Failures: 0, Errors: 0' "/out/logs/$lg.log")
		sig=$(grep -oE 'killed by signal [0-9]+ [A-Z]+' "/out/logs/$lg.log" | head -1)
		cp /work/src/build/meson-logs/testlog.txt "/out/logs/$lg.meson-testlog.txt" 2>/dev/null
		printf '{"suite":"%s","iter":%d,"log":"%s","rc":%d,"seconds":%s,"meson_ok":%s,"meson_fail":%s,"meson_skip":%s,"meson_timeout":%s,"meson_xfail":%s,"meson_upass":%s,"xml":%s,"checks":%d,"check_failures":%d,"check_errors":%d,"checks_0_line":%d,"signal":"%s","wrapper_timeout":%s,"mem_avail_mb_start":%s,"mem_avail_mb_end":%s,"load1_start":%s,"load1_end":%s}\n' \
			"$s" "$it" "$lg" "$rc" "$secs" "$ok" "$fail" "$skipped" "$tmo" "$xfail" "$upass" "$hasxml" "$nt" "$nf" "$ne" "$checks0" "$sig" \
			"$([ $rc -eq 124 ] && echo true || echo false)" "$mem0" "$mem1" "$load0" "$load1" >> /out/results.jsonl
		log "[$i/$total] $s#$it rc=$rc ${secs}s ok=$ok fail=$fail checks=$nt${sig:+ $sig}"
	done
done < /out/_only.txt
log "done: $(wc -l < /out/results.jsonl) results"
