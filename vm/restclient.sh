#!/bin/bash
# Stand up the REST API client host the danos_restapi suite drives the router
# from.
#
# The suite does not talk to the router directly. It SSHes to ${RESTClient} --
# 192.168.203.6, user test / test123 -- and runs curl there against the
# router's HTTPS listener, so that host has to exist before the suite starts.
# Without it every case fails identically:
#
#   NoValidConnectionsError: Unable to connect to port 22 on 192.168.203.6
#
# which says nothing about REST and reads as the router being unreachable. 19
# of 21 failed that way here.
#
# The image has to carry openssh-server and curl already. Installing them at
# container start means apt-get inside the container, which has hung here
# holding /var/lib/apt/lists/lock -- the container comes up, stays useless, and
# the failure surfaces much later as the suite failing to connect. That is how
# the previous hand-made danos-restclient container was built, and it is the
# same trap relays.sh documents for socat. danos-build:trixie has both.
#
# Usage: restclient.sh up|down

set -u
NET=danos-mgmt
IP=${RESTCLIENT_IP:-192.168.203.6}
NAME=danos-restclient
IMAGE=${RESTCLIENT_IMAGE:-danos-build:trixie}
USER_NAME=test
USER_PASS=test123

up() {
	docker network inspect "$NET" >/dev/null 2>&1 || \
		docker network create --subnet 192.168.203.0/24 --gateway 192.168.203.1 "$NET" >/dev/null
	docker rm -f "$NAME" >/dev/null 2>&1

	# sshd needs its host keys and a place to drop the pid; both are missing in
	# a fresh container and neither is created on demand.
	docker run -d --name "$NAME" --network "$NET" --ip "$IP" "$IMAGE" sh -c "
		useradd -m -s /bin/bash $USER_NAME 2>/dev/null
		echo '$USER_NAME:$USER_PASS' | chpasswd
		mkdir -p /run/sshd
		ssh-keygen -A >/dev/null 2>&1
		printf 'PermitRootLogin no\nPasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/test.conf
		exec /usr/sbin/sshd -D
	" >/dev/null

	for i in $(seq 1 30); do
		if docker exec "$NAME" sh -c 'command -v curl >/dev/null && pgrep -x sshd >/dev/null' 2>/dev/null; then
			printf '  %-18s %s up (user %s)\n' "$IP" "$NAME" "$USER_NAME"
			return 0
		fi
		sleep 1
	done
	echo "  $NAME did not come up:" >&2
	docker logs "$NAME" 2>&1 | sed 's/^/      /' >&2
	return 1
}

down() {
	docker rm -f "$NAME" >/dev/null 2>&1 && echo "  $NAME removed"
}

case "${1:-up}" in
up)   up ;;
down) down ;;
*)    echo "usage: restclient.sh up|down" >&2; exit 1 ;;
esac
