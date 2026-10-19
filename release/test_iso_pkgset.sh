#!/bin/bash
# Deterministic probes for iso-pkgset.sh: no ISO, no build.
set -u
H="$(cd "$(dirname "$0")" && pwd)/iso-pkgset.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want $2, got $3)"; fail=1; fi; }

pkg() { printf 'Package: %s\nStatus: %s\nArchitecture: amd64\nVersion: %s\n\n' "$1" "${4:-install ok installed}" "$2"; }
{ pkg frr 10.1-danos1; pkg bash 5.2-1; pkg gone 1 x "deinstall ok config-files"; } > "$T/a.status"
{ pkg bash 5.2-1; pkg frr 10.1-danos1; } > "$T/same.status"
{ pkg bash 5.2-1; pkg frr 10.1-danos2; } > "$T/ver.status"
{ pkg bash 5.2-1; } > "$T/miss.status"
for n in a same ver miss; do "$H" status < "$T/$n.status" > "$T/$n.set"; done

check "removed package is ignored" "2" "$(wc -l < "$T/a.set" | tr -d ' ')"
"$H" diff "$T/a.set" "$T/same.set" >/dev/null 2>&1;  check "identical sets" 0 $?
"$H" diff "$T/a.set" "$T/ver.set" >/dev/null 2>&1;   check "version changed" 1 $?
"$H" diff "$T/a.set" "$T/miss.set" >/dev/null 2>&1;  check "package missing" 1 $?
: > "$T/empty.set"
"$H" diff "$T/empty.set" "$T/empty.set" >/dev/null 2>&1; check "two empty sets are not identical" 1 $?
"$H" extract "$T/nonexistent.iso" >/dev/null 2>&1;   check "missing ISO" 1 $?
bash -n "$H" && bash -n "$(dirname "$H")/close-the-loop.sh"; check "syntax" 0 $?
exit $fail
