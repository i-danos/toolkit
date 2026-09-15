#!/bin/bash
# Which image are the running VMs actually booted from?
#
# Every result this toolkit produces is a statement about an image, and until
# now not one of them recorded which. That gap was not theoretical: a dataplane
# fix was measured as ineffective, and correctly so -- the VMs answering were
# still running the image from before it, because boot-topo.sh had never
# stopped the previous topology and the new qemu could not lock the pidfile.
# The ISO name was printed at the top of the run, from the variable that was
# *asked for*. Nothing read what was *running*.
#
# qemu's own command line is the answer and it cannot drift: the VM is booted
# from the file named there. /proc/<pid>/cmdline, via the pidfile.
#
# Usage:
#   image-fingerprint.sh              one line, for a log header
#   image-fingerprint.sh --assert <iso>
#                                     exit non-zero unless every running VM
#                                     boots that image
#   image-fingerprint.sh --list       one line per router
#
# "MIXED" is a finding, not an error case to paper over. Half the routers on
# one image and half on another is exactly the state that produced 22
# regression failures reading as product defects.
set -u

RUNBASE=${OBS_DIR:-/home/aikon/danos/.obs}/run

# The ISO a router is booted from, or "" if it is not running.
iso_of() {
	local run=$RUNBASE/$1 pid exe
	[ -f "$run/qemu.pid" ] || return 0
	pid=$(cat "$run/qemu.pid" 2>/dev/null)
	case "$pid" in ''|*[!0-9]*) return 0 ;; esac
	exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null)
	case "$exe" in *qemu-system-*) ;; *) return 0 ;; esac
	# -drive file=<iso>,media=cdrom,... The path may be relative to whatever
	# directory boot-topo.sh ran in, so only the basename is comparable.
	tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null \
	  | sed -n 's/^file=\(.*\),media=cdrom.*/\1/p' | head -1 | xargs -r basename
}

routers() {
	local d
	for d in "$RUNBASE"/*; do
		[ -d "$d" ] || continue
		basename "$d"
	done
}

collect() {
	local r i
	for r in $(routers); do
		i=$(iso_of "$r")
		[ -n "$i" ] || continue
		printf '%s %s\n' "$r" "$i"
	done
}

# What is actually installed, asked of a booted router.
#
# The ISO name answers "which file did qemu open" and stops there. It cannot
# answer "does that file contain the change this run is for", and the two came
# apart in this project: OBS silently refused to build two bumped packages, the
# repository kept serving the previous binaries, and the ISO was rebuilt from
# them under a fresh timestamped name. A name-only fingerprint calls that
# image new, because it is -- new file, old contents.
#
# So this asks the box. Package versions, because that is what the repository
# actually delivered, and a probe for each field the run depends on, because a
# version can be installed without the behaviour being reachable.
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
CONTENT_HOST=${CONTENT_HOST:-192.168.203.155}

on_router() {
	docker exec danos-robot timeout 60 sshpass -p vyatta ssh $SSH_OPTS \
	       "vyatta@$CONTENT_HOST" "$1" 2>/dev/null
}

contents() {
	on_router 'for p in vyatta-dataplane vyatta-route-broker-frr; do
	              printf "  %-26s %s\n" "$p" "$(dpkg-query -W -f=\${Version} $p 2>/dev/null || echo ABSENT)"
	           done
	           printf "  %-26s %s\n" "dpa dataplane_owned" \
	             "$(sudo /opt/vyatta/bin/vplsh -l -c "dpa object show route" 2>/dev/null \
	                | grep -c dataplane_owned)"
	           # grep -c exits 1 on a count of zero, which is the answer we
	           # want here, not an error -- "|| echo ?" appended a second line
	           # to the one that was already correct.
	           printf "  %-26s %s\n" "brokerd pthread_cancel" \
	             "$(grep -c pthread_cancel /usr/sbin/brokerd 2>/dev/null; true)"'
}

case "${1:-}" in
--contents)
	contents
	;;
--assert-contents)
	# Two-way, deliberately. "The new version is present" passes just as well
	# when the old one is also still there, and a wait condition written that
	# way matched a stale truth three times in one hour on this project.
	want_dp=${2:?usage: --assert-contents <dataplane-ver> <broker-ver>}
	want_rb=${3:?usage: --assert-contents <dataplane-ver> <broker-ver>}
	got=$(contents)
	[ -n "$got" ] || { echo "  CONTENTS: router did not answer" >&2; exit 1; }
	printf '%s\n' "$got"
	bad=0
	got_dp=$(printf '%s\n' "$got" | awk '$1=="vyatta-dataplane"{print $2}')
	got_rb=$(printf '%s\n' "$got" | awk '$1=="vyatta-route-broker-frr"{print $2}')
	[ "$got_dp" = "$want_dp" ] || { echo "  CONTENT MISMATCH: dataplane is $got_dp, expected $want_dp" >&2; bad=1; }
	[ "$got_rb" = "$want_rb" ] || { echo "  CONTENT MISMATCH: route-broker is $got_rb, expected $want_rb" >&2; bad=1; }
	if [ "$bad" -ne 0 ]; then
		echo "  The ISO may still be the right file. Its contents are not the" >&2
		echo "  ones this run is for, which is the failure a name-only" >&2
		echo "  fingerprint was built to miss." >&2
		exit 1
	fi
	echo "  contents: dataplane $got_dp, route-broker $got_rb -- both as expected"
	;;
--list)
	collect | sed 's/^/  /'
	;;
--assert)
	want=$(basename "${2:?usage: image-fingerprint.sh --assert <iso>}")
	rows=$(collect)
	if [ -z "$rows" ]; then
		echo "  IMAGE: no VM is running -- nothing to assert against" >&2
		exit 1
	fi
	bad=0
	while read -r r got; do
		[ "$got" = "$want" ] || {
			echo "  IMAGE MISMATCH: $r boots $got, this run is for $want" >&2
			bad=$((bad + 1))
		}
	done <<-EOF
	$rows
	EOF
	if [ "$bad" -ne 0 ]; then
		echo "  Refusing. A result measured here would be a statement about" >&2
		echo "  the wrong image, which is indistinguishable from a statement" >&2
		echo "  about the right one that happens to be false." >&2
		exit 1
	fi
	# printf '%s\n', not '%s'. Without the newline wc -l counts one short,
	# which is how this line first reported "2 routers agree" about three.
	echo "  image: $want  ($(printf '%s\n' "$rows" | wc -l | tr -d ' ') routers agree)"
	;;
*)
	rows=$(collect)
	if [ -z "$rows" ]; then
		echo "  image: no VM running"
		exit 0
	fi
	uniq_isos=$(printf '%s\n' "$rows" | awk '{print $2}' | sort -u)
	if [ "$(printf '%s\n' "$uniq_isos" | wc -l)" -eq 1 ]; then
		printf '  image: %s  (%s routers)\n' "$uniq_isos" \
		       "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')"
	else
		printf '  image: MIXED --%s\n' \
		       "$(printf '%s\n' "$rows" | awk '{printf " %s=%s", $1, $2}')"
	fi
	;;
esac
