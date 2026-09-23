#!/bin/bash
# Is this router's qemu process actually what its pidfile claims it is?
#
# The readiness gate's own vocabulary (see docs, "验收流程要求") lists nine
# conditions, and boot-and-prep.sh already checks most of them: console login
# (via prep-router.sh), non-interactive sudo, exact dataplane port wiring, ISO
# fingerprint. What it infers rather than checks directly is the first one on
# the list -- "QEMU PID 和端口有效" -- by assuming that if ssh answers, the
# process behind it must be sane. That assumption is usually right and cheap
# enough to make, which is why nothing broke without this script. It is not
# always right: a stale pidfile pointing at a *reused* pid (some unrelated
# process that happens to now own that number), or a qemu that started but
# never actually bound its hostfwd port, both produce a router that "isn't
# reachable yet" indistinguishable from one that is simply still booting --
# the exact ambiguity a readiness gate exists to remove.
#
# So: check the process and the port directly, before anything that depends on
# them times out and reads as a slow boot instead of a wrong one.
#
# Usage: vm-sanity.sh <run-dir> <host-ssh-port>
#   run-dir       the router's own directory under $OBS_DIR/run/<name>,
#                 holding qemu.pid, console.sock, monitor.sock
#   host-ssh-port the port qemu's hostfwd maps to guest:22, on 127.0.0.1
#
# Exit 0 and silent on success. Exit 1 with one line per failed check
# otherwise -- boot-and-prep.sh treats any output as a name worth folding
# into its own BLOCKED reason, not as a reason to guess further.
set -u

RUN=${1:?usage: vm-sanity.sh <run-dir> <host-ssh-port>}
PORT=${2:?usage: vm-sanity.sh <run-dir> <host-ssh-port>}

bad=0
fail() { echo "  $1" >&2; bad=1; }

pidfile="$RUN/qemu.pid"
if [ ! -f "$pidfile" ]; then
	fail "no qemu.pid in $RUN -- boot-topo.sh never wrote one, or something removed it"
	exit 1
fi

pid=$(cat "$pidfile" 2>/dev/null)
case "$pid" in
	''|*[!0-9]*)
		fail "qemu.pid in $RUN does not contain a number: '$pid'"
		exit 1
		;;
esac

if [ ! -d "/proc/$pid" ]; then
	fail "pid $pid from $pidfile is not running -- the process behind this router is gone"
	exit 1
fi

# The check that actually matters: is this pid *still* the qemu it was when
# the pidfile was written, or has the pid been reused by something else
# entirely since? Linux recycles pids; a long enough gap between boot-topo.sh
# writing the file and this check running makes that not just theoretical.
exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null)
case "$exe" in
	*/qemu-system-*) ;;
	*)
		fail "pid $pid from $pidfile is '$exe', not qemu-system-* -- stale pidfile, reused pid"
		bad=1
		;;
esac

for sock in console.sock monitor.sock; do
	if [ ! -S "$RUN/$sock" ]; then
		fail "$RUN/$sock is missing or not a socket"
		bad=1
	fi
done

# The hostfwd port: qemu's user-mode networking binds this on the host side,
# independent of anything happening inside the guest, so it comes up as soon
# as qemu itself starts -- a port that never opens means qemu never got that
# far, not that the guest is slow to boot. A bare /dev/tcp probe needs no
# extra tooling and a closed/refused port fails it immediately rather than
# hanging for a connect timeout.
if ! timeout 3 bash -c ": >/dev/tcp/127.0.0.1/$PORT" 2>/dev/null; then
	fail "127.0.0.1:$PORT (this router's hostfwd ssh port) is not accepting connections"
	bad=1
fi

exit $bad
