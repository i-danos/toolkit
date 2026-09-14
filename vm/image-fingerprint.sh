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

case "${1:-}" in
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
