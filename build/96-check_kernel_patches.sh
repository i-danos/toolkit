#!/bin/sh
# Check that debian/patches-vyatta applies the way the build applies it.
#
# debian/rules.real uses `quilt push -a -q --fuzz=0`. Verifying locally with
# `quilt push -a -f` proves nothing: -f is exactly "allow fuzz". A stable
# import that shifts context near a patch passes the -f check and fails on the
# build host, halfway through binary-indep.
#
# Extracts only the files the series touches (~2.5 MB, not the 1.8 GB tree)
# and replays the series with patch -F0, which is what --fuzz=0 means.
#
# Usage: 96-check_kernel_patches.sh [path-to-linux-vyatta]
# Exit 0 = every patch applies at fuzz 0.

set -eu

SRC=${1:-.}
cd "$SRC"

[ -f debian/patches-vyatta/series ] || {
	echo "not a linux-vyatta tree: $SRC" >&2
	exit 2
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
P=$PWD/debian/patches-vyatta

# Files the series touches. New files show as /dev/null and are skipped here;
# patch creates them.
while read -r p; do
	case "$p" in ''|\#*) continue ;; esac
	grep -h '^--- a/' "$P/$p" || true
done < debian/patches-vyatta/series \
	| sed 's#^--- a/##' | LC_ALL=C sort -u > "$WORK/files"

while read -r f; do
	[ "$f" = "/dev/null" ] && continue
	mkdir -p "$WORK/tree/$(dirname "$f")"
	cp "$f" "$WORK/tree/$f"
done < "$WORK/files"

cd "$WORK/tree"
fail=0
n=0
while read -r p; do
	case "$p" in ''|\#*) continue ;; esac
	n=$((n + 1))
	if ! out=$(patch -p1 -F0 -s --no-backup-if-mismatch < "$P/$p" 2>&1); then
		fail=$((fail + 1))
		echo "FAIL $p"
		echo "$out" | sed 's/^/     /'
	elif [ -n "$out" ]; then
		fail=$((fail + 1))
		echo "FAIL $p"
		echo "$out" | sed 's/^/     /'
	fi
done < "$P/series"

echo "patches-vyatta: $n patches, $fail need fuzz"
[ "$fail" -eq 0 ] || cat <<'EOF'

Do not add fuzz tolerance. Regenerate the context instead: apply the series up
to the patch before the failing one, apply the failing one with fuzz allowed,
diff -u the file it could not place, and replace that file's section in the
patch. Semantics unchanged, context realigned. See toolkit/docs/TRAPS.md.
EOF
exit "$fail"
