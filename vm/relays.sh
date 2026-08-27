#!/bin/bash
# Give each router a fixed address on 192.168.203.0/24, as the DANOS test
# suites hard-code.
#
# The suites SSH to the routers by IP, so each one needs its own address that
# Robot can reach. QEMU user-mode networking cannot be reached inbound at all,
# and putting the VMs on a bridge needs a tap device, which needs root --
# qemu-bridge-helper is not setuid here. What is available without root is
# docker, so each router gets a tiny container holding its address and relaying
# 22 and 443 to that VM's hostfwd ports on the docker gateway.
#
# Usage: relays.sh up [<name>:<ip>:<sshport> ...]
#        relays.sh down
#
# Default layout matches the FIREWALL/IPSEC suites: R1 .231, R2 .232, R3 .233.

set -u
NET=danos-mgmt
GW=192.168.203.1
# An image that already carries socat. Installing it at container start means
# apt-get inside the container, which has hung here holding
# /var/lib/apt/lists/lock -- every relay comes up and stays useless, and the
# failure surfaces much later as the test suite failing to connect.
#
# Create it once from the build container, which has socat installed:
#   docker commit danos-2110b-build danos-relay:socat
IMAGE=${RELAY_IMAGE:-danos-relay:socat}
DEFAULT=(r1:192.168.203.231:2231 r2:192.168.203.232:2232 r3:192.168.203.233:2233)

up() {
  local specs=("$@"); [ ${#specs[@]} -eq 0 ] && specs=("${DEFAULT[@]}")
  docker network inspect "$NET" >/dev/null 2>&1 || \
    docker network create --subnet 192.168.203.0/24 --gateway "$GW" "$NET" >/dev/null

  for s in "${specs[@]}"; do
    IFS=: read -r name ip sshport <<<"$s"
    local https=$((sshport + 200))
    docker rm -f "danos-relay-$name" >/dev/null 2>&1
    # Both ports are relayed from one container.
    docker run -d --name "danos-relay-$name" --network "$NET" --ip "$ip" "$IMAGE" \
      sh -c "socat TCP-LISTEN:22,fork,reuseaddr TCP:$GW:$sshport &
             socat TCP-LISTEN:443,fork,reuseaddr TCP:$GW:$https" >/dev/null
    printf '  %-4s %-16s ssh->%s https->%s\n' "$name" "$ip" "$sshport" "$https"
  done
  # Count the relays up front. Reading ${#specs[@]} inside the loop has bitten
  # this before: the comparison silently never matched and the function
  # reported a timeout while every container was in fact ready.
  local want=${#specs[@]}
  echo "  waiting for relays ($want) ..."
  for _ in $(seq 1 60); do
    sleep 5
    local ready=0
    for s in "${specs[@]}"; do
      IFS=: read -r name _ _ <<<"$s"
      docker exec "danos-relay-$name" sh -c 'command -v socat >/dev/null' 2>/dev/null && ready=$((ready + 1))
    done
    if [ "$ready" -eq "$want" ]; then echo "  all $ready relays ready"; return 0; fi
  done
  echo "  only $ready of $want relays ready" >&2; return 1
}

down() {
  for c in $(docker ps -aq --filter "name=danos-relay-" 2>/dev/null); do
    docker rm -f "$c" >/dev/null 2>&1
  done
  echo "  relays removed"
}

case "${1:-up}" in
  up)   shift || true; up "$@" ;;
  down) down ;;
  *)    echo "usage: relays.sh up|down" >&2; exit 1 ;;
esac
