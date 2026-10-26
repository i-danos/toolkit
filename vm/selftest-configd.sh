#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-only
# Run configd's server/ tests in a throwaway root container.
#
# This is NOT part of the package build. debian/rules skips configd's test run
# (configd commit 0d025e7) because the tests need things only an installed
# system has, and the build cannot create them:
#
#   /var/tmp/configd, /run/vyatta/configd   debian/configd.tmpfile, applied by
#                                           systemd-tmpfiles at install time
#   /config                                 server/dispatcher.go hard-codes
#                                           /config/config.boot
#   /opt/vyatta/sbin/vyatta_current_conf_ver.pl
#                                           server/config_mgmt.go execs it by
#                                           absolute path; without it a saved
#                                           config has no version trailer and
#                                           the next SaveTo refuses to overwrite
#
# The build user is unprivileged (OBS), and fakeroot does not help: it fakes
# ownership, it does not grant the right to create /config, and dh_auto_test
# does not even run under it. Measured, not assumed -- handoff/runs/
# r2-r2-20261026/probe.log. A root container can create all of it, so this runs
# the tests there, from a copy of the source, and throws the container away.
#
# Everything created below exists only inside the container: the version script
# is a stub, and none of it reaches the host tree or any .deb.
#
# Usage:
#   selftest-configd.sh [--keep]
# Environment:
#   IMAGE     packaging image            (default danos-pkgbuild:2608-r3)
#   APT_URL   apt source holding the danos -dev build dependencies
#             (default http://172.17.0.1:8080/, the docker bridge gateway)
#   REPO_DIR  if APT_URL is unreachable and this is set, serve it with
#             python3 http.server for the duration of the run, then stop it
#   SRC       danos-sources directory    (default: this script's parent's parent)
#   LOG_DIR   where the log goes         (default $SRC/../../handoff/runs)
#   KEEP=1    same as --keep: leave the container for inspection
# Exit status is that of `go test`; 2 for a harness problem.
#
# Not covered: the session/ tests. They import github.com/danos/godbus/dbus,
# for which no -dev package exists, so they cannot compile in any build
# environment; this script only runs ./server/. See toolkit/README.md.

set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=${SRC:-$(cd "$HERE/../.." && pwd)}
IMAGE=${IMAGE:-danos-pkgbuild:2608-r3}
APT_URL=${APT_URL:-http://172.17.0.1:8080/}
REPO_DIR=${REPO_DIR:-}
LOG_DIR=${LOG_DIR:-$SRC/../../handoff/runs}
KEEP=${KEEP:-0}
[ "${1:-}" = "--keep" ] && KEEP=1

ts=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$LOG_DIR"
LOG_DIR=$(cd "$LOG_DIR" && pwd)
LOG=$LOG_DIR/selftest-configd-$ts.log
name=selftest-configd-$ts

[ -d "$SRC/configd" ] || { echo "no configd source at $SRC/configd" >&2; exit 2; }
docker image inspect "$IMAGE" >/dev/null 2>&1 \
  || { echo "image $IMAGE not found" >&2; exit 2; }

work=$(mktemp -d)
http_pid=
cleanup() {
  [ -n "$http_pid" ] && kill "$http_pid" 2>/dev/null
  [ "$KEEP" = 1 ] || docker rm -f "$name" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

# The container sees only this copy, so nothing it does can touch the checkout.
rsync -a --exclude=.git "$SRC/configd/" "$work/configd/" \
  || { echo "rsync of configd failed" >&2; exit 2; }

if ! curl -fs -m 5 -o /dev/null "${APT_URL%/}/Packages.gz"; then
  if [ -n "$REPO_DIR" ]; then
    port=${APT_URL%/}; port=${port##*:}
    python3 -m http.server "$port" --bind 0.0.0.0 \
      --directory "$REPO_DIR" >/dev/null 2>&1 &
    http_pid=$!
    sleep 1
  fi
  curl -fs -m 5 -o /dev/null "${APT_URL%/}/Packages.gz" \
    || { echo "apt source $APT_URL is not reachable (set REPO_DIR to serve one)" >&2; exit 2; }
fi

cat > "$work/inner.sh" <<'EOF'
#!/bin/bash
set -u
echo "deb [trusted=yes] ${APT_URL} ./" > /etc/apt/sources.list.d/selftest.list
apt-get update -qq >/dev/null
cd /src/configd || exit 2
apt-get build-dep -y . >/dev/null 2>&1 || { echo "build-dep failed" >&2; exit 2; }

# What an installed system provides and the unprivileged build cannot.
mkdir -p /run/vyatta/configd /config /opt/vyatta/sbin
install -d -m 1700 /var/tmp/configd
# Stub for the real version script (vyatta-cfg). Container only; the format
# just has to contain "=== vyatta-config" so isVyattaConfigFile accepts it.
printf '#!/bin/sh\necho "/* === vyatta-config-version: \\"selftest@1\\" === */"\n' \
  > /opt/vyatta/sbin/vyatta_current_conf_ver.pl
chmod +x /opt/vyatta/sbin/vyatta_current_conf_ver.pl
echo "== created (container only):"
ls -ld /var/tmp/configd /run/vyatta/configd /config /opt/vyatta/sbin/vyatta_current_conf_ver.pl

mkdir -p /tmp/gp/src/github.com/danos
ln -sfn /src/configd /tmp/gp/src/github.com/danos/configd
export GOPATH=/tmp/gp:/usr/share/gocode GO111MODULE=off GOCACHE=/tmp/gc HOME=/tmp
cd /tmp/gp/src/github.com/danos/configd || exit 2
go version; echo "euid=$(id -u)"
# -vet=off matches what dh_auto_test passes.
go test -vet=off ./server/ -v
EOF
chmod +x "$work/inner.sh"

docker run --name "$name" $([ "$KEEP" = 1 ] || echo --rm) \
  --env APT_URL="${APT_URL%/}/" \
  --volume "$work:/src" \
  "$IMAGE" /src/inner.sh 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

pass=$(grep -c '^--- PASS' "$LOG"); fail=$(grep -c '^--- FAIL' "$LOG"); skip=$(grep -c '^--- SKIP' "$LOG")
echo "server/: PASS=$pass FAIL=$fail SKIP=$skip  exit=$rc" | tee -a "$LOG"
echo "log: $LOG"
[ "$KEEP" = 1 ] && echo "container kept: docker exec -it $name bash   (docker rm -f $name when done)"
exit "$rc"
