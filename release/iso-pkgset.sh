#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-only
# The package set an ISO really installs: name:arch and version, read from the
# dpkg database inside its squashfs rather than from the .packages manifest
# that live-build writes next to it. The two should agree; this is the check
# that they do, and that two ISOs carry the same software.
#
# Usage:
#   iso-pkgset.sh status < dpkg-status      installed packages, sorted
#   iso-pkgset.sh extract <iso>             same, read out of the ISO
#   iso-pkgset.sh compare <iso-a> <iso-b>   exit non-zero on any difference
#   iso-pkgset.sh diff <set-a> <set-b>      the comparison on two extracted sets
set -u

status_to_set() {
	awk -v RS= -F'\n' '
	{
		name = ""; arch = ""; ver = ""; ok = 0
		for (i = 1; i <= NF; i++) {
			if ($i ~ /^Package: /)       name = substr($i, 10)
			else if ($i ~ /^Architecture: /) arch = substr($i, 15)
			else if ($i ~ /^Version: /)  ver = substr($i, 10)
			else if ($i ~ /^Status: /)   ok = ($i ~ / installed$/ && $i !~ / not-installed$/)
		}
		if (ok && name != "" && ver != "") print name ":" arch, ver
	}' | LC_ALL=C sort
}

extract() {
	local iso=$1 tmp rc
	[ -f "$iso" ] || { echo "no such ISO: $iso" >&2; return 1; }
	tmp=$(mktemp -d) || return 1
	if xorriso -osirrox on -indev "$iso" -extract /live/filesystem.squashfs "$tmp/fs.squashfs" >/dev/null 2>&1 \
	   && unsquashfs -cat "$tmp/fs.squashfs" var/lib/dpkg/status > "$tmp/status" 2>/dev/null; then
		status_to_set < "$tmp/status"; rc=0
	else
		echo "cannot read the dpkg database from $iso" >&2; rc=1
	fi
	chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"
	return $rc
}

# Fails on an empty set too: two empty extractions must not read as "identical".
diff_sets() {
	[ -s "$1" ] && [ -s "$2" ] || { echo "empty or missing package set" >&2; return 1; }
	diff -u "$1" "$2"
}

case "${1:-}" in
	status)  status_to_set ;;
	extract) extract "${2:?usage: $0 extract <iso>}" ;;
	diff)    diff_sets "${2:?}" "${3:?}" ;;
	compare)
		a=$(mktemp); b=$(mktemp)
		trap 'rm -f "$a" "$b"' EXIT
		extract "${2:?usage: $0 compare <iso-a> <iso-b>}" > "$a" && extract "${3:?}" > "$b" || exit 1
		diff_sets "$a" "$b" ;;
	*) echo "usage: $0 status|extract|compare|diff ..." >&2; exit 2 ;;
esac
