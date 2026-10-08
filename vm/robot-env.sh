#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build and start the container environment vm/regression.sh needs.
#
# Before this script the environment existed only as images committed by hand
# (docker commit), so a `docker image prune` removed it and the next regression
# failed in ways that read as product problems: "robot: executable file not
# found", then "danos-relay:socat" missing, then "danos-build:trixie" missing.
#
# Usage: robot-env.sh up|down|status
#   up      build the image if absent, tag it for all three roles, create the
#           management network, (re)start the danos-robot container
#   down    remove the danos-robot container (images stay)
#   status  say what is present
#
# Environment:
#   TESTS_DIR        directory mounted as /tests (default: the checkout's tests/)
#   DEBIAN_MIRROR    apt mirror used while building the image
#   REBUILD=1        rebuild the image even if it exists
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
IMAGE=danos-robot:latest
NET=danos-mgmt
ROBOT_IP=192.168.203.200
TESTS_DIR=${TESTS_DIR:-$(cd "$HERE/../../tests" 2>/dev/null && pwd)}

build() {
	local args=()
	[ -n "${DEBIAN_MIRROR:-}" ] && args+=(--build-arg "DEBIAN_MIRROR=$DEBIAN_MIRROR")
	docker build "${args[@]}" -t "$IMAGE" "$HERE/robot-env" || return 1
	docker tag "$IMAGE" danos-relay:socat
	docker tag "$IMAGE" danos-build:trixie
}

up() {
	[ -d "${TESTS_DIR:-}" ] || { echo "no tests directory at '${TESTS_DIR:-}'; set TESTS_DIR" >&2; return 1; }
	if [ "${REBUILD:-0}" = 1 ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
		build || return 1
	else
		# The image survived but a role tag may not have.
		docker tag "$IMAGE" danos-relay:socat
		docker tag "$IMAGE" danos-build:trixie
	fi
	docker network inspect "$NET" >/dev/null 2>&1 || \
		docker network create --subnet 192.168.203.0/24 --gateway 192.168.203.1 "$NET" >/dev/null || return 1
	docker rm -f danos-robot >/dev/null 2>&1
	docker run -d --name danos-robot --network "$NET" --ip "$ROBOT_IP" \
		-v "$TESTS_DIR:/tests" "$IMAGE" >/dev/null || return 1
	docker exec danos-robot robot --version
}

down() {
	docker rm -f danos-robot >/dev/null 2>&1
	echo "danos-robot removed"
}

status() {
	local ok=0 i
	for i in "$IMAGE" danos-relay:socat danos-build:trixie; do
		if docker image inspect "$i" >/dev/null 2>&1; then echo "  image     $i"; else echo "  MISSING   image $i"; ok=1; fi
	done
	if docker network inspect "$NET" >/dev/null 2>&1; then echo "  network   $NET"; else echo "  MISSING   network $NET"; ok=1; fi
	if [ "$(docker inspect -f '{{.State.Running}}' danos-robot 2>/dev/null)" = true ]; then
		echo "  container danos-robot running"
	else
		echo "  MISSING   container danos-robot (not running)"; ok=1
	fi
	return $ok
}

case "${1:-}" in
	up) up ;;
	down) down ;;
	status) status ;;
	*) echo "usage: $0 up|down|status" >&2; exit 2 ;;
esac
