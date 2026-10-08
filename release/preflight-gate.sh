#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Preflight for the release gate: the checks that this project's own runs have
# gotten sideways on, reported as a named cause rather than a downstream
# timeout that reads as a product failure.
#
# Every failure this catches actually happened this week and was first
# misdiagnosed as something else:
#
#   - danos-robot stopped (a host restart stops every container) -> every
#     ssh in accept-disk-install.sh / accept-lifecycle.sh / regression.sh
#     failed, and the first boot "did not reach ssh" -- read as the product
#     not booting.
#   - the local apt repo's HTTP server, which is not persistent and does not
#     survive a container restart, was down -> lb build fails hundreds of
#     lines into a chroot with "Unable to locate package", which reads like
#     a missing package, not a missing server.
#   - disk near full, twice, mid-build -> lb build dies with "No space left
#     on device" deep in package extraction.
#   - a stray QEMU process left over from a killed prior run held a
#     hostfwd port -> the next boot's ssh silently went to the wrong guest.
#   - a large unrelated process ate most of host memory -> a 3 GB guest took
#     minutes to reach a login prompt and tripped a 420s boot timeout that
#     had nothing to do with the image under test.
#
# None of this replaces the build or the acceptance scripts. It runs first and
# says which of the above is true, in one place, instead of each script
# discovering it separately with a different, less specific symptom.
#
# Usage: preflight-gate.sh [--for=build|vm|both]
#   build   the container, the local repo server, disk space in /
#   vm      danos-robot, stray qemu processes, available memory
#   both    everything (default)
set -u
FOR=both
for a in "$@"; do case "$a" in --for=*) FOR=${a#--for=} ;; *) echo "usage: $0 [--for=build|vm|both]" >&2; exit 2 ;; esac; done

BUILD_CONTAINER=${BUILD_CONTAINER:-danos-2110b-build}
OBS_REPO_IN_CONTAINER=${OBS_REPO_IN_CONTAINER:-/build-iso/danos-build/obs-repo}
MIN_DISK_FREE_GB=${MIN_DISK_FREE_GB:-15}
MIN_MEM_AVAIL_MB=${MIN_MEM_AVAIL_MB:-4096}
DISK_PATH=${DISK_PATH:-/}

# /.dockerenv exists only inside a container. It decides which of two
# otherwise-identical checks runs: from the host, "is the repo server up" has
# to go through docker exec, because 127.0.0.1 inside the container is not
# 127.0.0.1 on the host (see local-repo-http-server notes) -- checking from the
# host proves nothing. From inside the container (90-mk-test-iso.sh and
# 91-mk-product-iso.sh run here), there is no docker to exec through, and
# 127.0.0.1 is now the right address to ask directly. /build-iso is where the
# host disk is bind-mounted, and reports the same numbers "df /" does on the
# host -- it is the disk that actually runs out, not the container's own thin
# overlay root.
IN_CONTAINER=0
[ -e /.dockerenv ] && IN_CONTAINER=1
[ "$IN_CONTAINER" = 1 ] && [ "$DISK_PATH" = / ] && [ -d /build-iso ] && DISK_PATH=/build-iso

bad=0
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
no()   { printf '  \033[31mFAIL\033[0m  %s -- %s\n' "$1" "$2"; bad=1; }

check_build() {
	echo "== build =="
	if [ "$IN_CONTAINER" = 1 ]; then
		code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/Release 2>/dev/null)
		if [ "$code" = 200 ]; then
			ok "the local apt repo server answers 200"
		else
			no "the local apt repo server answers 200" \
			   "got '${code:-no response}'; it is not persistent, start it: cd $OBS_REPO_IN_CONTAINER && nohup python3 -m http.server 8080 >/tmp/repo_server.log 2>&1 &"
		fi
	else
		if [ "$(docker inspect -f '{{.State.Running}}' "$BUILD_CONTAINER" 2>/dev/null)" = true ]; then
			ok "container $BUILD_CONTAINER is running"
		else
			no "container $BUILD_CONTAINER is running" "docker start $BUILD_CONTAINER (a host restart stops every container)"
		fi

		# The repo server is not persistent by design (see local-repo-http-server
		# notes): it has to be started inside the container's own network
		# namespace, on the container's own filesystem path, every time the
		# container restarts. Checking it from the host proves nothing -- the
		# host's 127.0.0.1 is not the container's.
		if [ "$(docker inspect -f '{{.State.Running}}' "$BUILD_CONTAINER" 2>/dev/null)" = true ]; then
			code=$(docker exec "$BUILD_CONTAINER" sh -c 'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/Release' 2>/dev/null)
			if [ "$code" = 200 ]; then
				ok "the local apt repo server answers 200 inside the container"
			else
				no "the local apt repo server answers 200 inside the container" \
				   "got '${code:-no response}'; start it: docker exec -d $BUILD_CONTAINER sh -c 'cd $OBS_REPO_IN_CONTAINER && nohup python3 -m http.server 8080 >/tmp/repo_server.log 2>&1'"
			fi
		else
			no "the local apt repo server answers 200 inside the container" "container is not running, see above"
		fi
	fi

	avail_kb=$(df -Pk "$DISK_PATH" | awk 'NR==2{print $4}')
	avail_gb=$(( avail_kb / 1024 / 1024 ))
	if [ "$avail_gb" -ge "$MIN_DISK_FREE_GB" ]; then
		ok "disk free on $DISK_PATH: ${avail_gb}G (>= ${MIN_DISK_FREE_GB}G)"
	else
		no "disk free on $DISK_PATH: ${avail_gb}G" "below ${MIN_DISK_FREE_GB}G; an ISO build has failed mid-way on less than this twice this project"
	fi
}

check_vm() {
	echo "== vm =="
	if [ "$(docker inspect -f '{{.State.Running}}' danos-robot 2>/dev/null)" = true ]; then
		ok "container danos-robot is running"
	else
		no "container danos-robot is running" "docker start danos-robot; every ssh in accept-disk-install.sh/accept-lifecycle.sh/regression.sh goes through it"
	fi

	stray=$(ps -eo pid,args | awk '$2 ~ /^qemu-system/ {print $1}')
	if [ -z "$stray" ]; then
		ok "no qemu-system process is running"
	else
		n=$(printf '%s\n' "$stray" | grep -c .)
		no "no qemu-system process is running" \
		   "$n running (pids: $(printf '%s' "$stray" | tr '\n' ' ')); a leftover process can hold a hostfwd port that the next boot's ssh silently goes to instead"
	fi

	avail_mb=$(free -m | awk 'NR==2{print $7}')
	if [ "$avail_mb" -ge "$MIN_MEM_AVAIL_MB" ]; then
		ok "memory available: ${avail_mb}M (>= ${MIN_MEM_AVAIL_MB}M)"
	else
		# Not fatal on its own -- a boot can still succeed slowly -- but every
		# BOOT_TIMEOUT in these scripts assumes headroom like this, and a run
		# that times out under memory pressure reads as the image, not the host.
		no "memory available: ${avail_mb}M" "below ${MIN_MEM_AVAIL_MB}M; a boot can time out slowly rather than fail, which reads as a product problem -- see if something unrelated is using it: ps -eo rss,comm --sort=-rss | head"
	fi
}

case "$FOR" in
	build) check_build ;;
	vm)    check_vm ;;
	both)  check_build; echo; check_vm ;;
esac

echo
if [ "$bad" = 0 ]; then
	echo "PREFLIGHT OK"
else
	echo "PREFLIGHT FAILED -- fix what is named above before trusting a build or acceptance run"
fi
exit "$bad"
