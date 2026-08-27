#!/bin/bash
# Static acceptance checks on a built ISO.
#
# The point of every check here is to be a discriminator: an observation that
# comes out DIFFERENT depending on whether the thing under test is true. A check
# whose result looks identical either way proves nothing, however reassuring it
# reads. That mistake was made once already — "the package manifest matches the
# previous ISO" was offered as evidence that packages came from OBS, when for
# the same set of packages the manifests are necessarily identical whatever the
# source.
#
# Usage: verify-iso.sh <path to .iso>

set -u
ISO=${1:?usage: verify-iso.sh <iso>}
[ -f "$ISO" ] || { echo "no such ISO: $ISO" >&2; exit 1; }

MNT=$(mktemp -d)
WORK=$(mktemp -d)
cleanup() { fusermount -u "$MNT" 2>/dev/null || umount "$MNT" 2>/dev/null; rm -rf "$MNT" "$WORK"; }
trap cleanup EXIT

pass=0; fail=0; warn=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
huh()  { printf '  \033[33mWARN\033[0m  %s\n' "$1"; warn=$((warn+1)); }

echo "== ISO: $(basename "$ISO")  ($(du -h "$ISO" | cut -f1), $(date -r "$ISO" '+%F %T')) =="
echo

# The manifest live-build writes alongside the ISO lists every installed
# package with its version. Prefer it; fall back to unpacking the squashfs.
# live-build names the manifest after the image but without the ".hybrid"
# infix: danos-2110b_<stamp>-amd64.hybrid.iso -> danos-2110b_<stamp>-amd64.packages
BASE=${ISO%.iso}; BASE=${BASE%.hybrid}
MAN=""
for c in "$BASE.packages" "${ISO%.iso}.packages" \
         "$(dirname "$ISO")/binary.packages" \
         "$(dirname "$ISO")/chroot.packages.install"; do
  [ -f "$c" ] && { MAN=$c; break; }
done
if [ -z "$MAN" ]; then
  echo "no package manifest found next to the ISO" >&2; exit 1
fi
echo "manifest: $MAN  ($(grep -c . "$MAN") entries)"
echo

# The manifest carries an :arch suffix on multi-arch packages
# (libpcap0.8t64:amd64), so strip it before comparing.
v()   { awk -v p="$1" '{n=$1; sub(/:.*/,"",n)} n==p {print $2; exit}' "$MAN"; }
has() { awk -v p="$1" '{n=$1; sub(/:.*/,"",n)} n==p {f=1} END{exit !f}' "$MAN"; }

echo "== 1. Release identity =="
# vyatta-version's version is computed at build time by debian/rules from
# /.build/build.dist, which OBS generates from the project prjconf macros.
# Without those macros OBS builds 1.3 — upstream's 2020 value. So this is a
# discriminator for "did the prjconf macros take effect", not decoration.
vv=$(v vyatta-version)
case "$vv" in
  2608) ok "vyatta-version = 2608" ;;
  1.3)  no "vyatta-version = 1.3 — the prjconf Macros: block did not take effect" ;;
  "")   no "vyatta-version absent from the manifest" ;;
  *)    huh "vyatta-version = $vv (expected 2608)" ;;
esac

echo
echo "== 2. Package source: OBS or the old local repository =="
# iproute was a hand-made transitional stub that only ever existed in
# local-repo; its three consumers now depend on iproute2, which is what OBS
# builds against. The two are mutually exclusive, so this splits the cases.
if has iproute; then
  no "iproute present — this is the hand-made stub, so packages came from local-repo"
else
  ok "iproute absent"
fi
if has iproute2; then ok "iproute2 present (version $(v iproute2))"
else no "iproute2 absent — expected it to replace the iproute stub"; fi

# The watchdog trio came from the abandoned vyatta-ipmi and was removed from
# the package lists; their presence would mean the lists were not applied.
wd=0
for p in vyatta-watchdog vyatta-system-watchdog-v1-yang vyatta-op-show-watchdog-v1-yang; do
  has "$p" && { no "$p still installed — it was removed from the package lists"; wd=1; }
done
[ $wd -eq 0 ] && ok "the three watchdog packages are gone"

# cloud-init had been commented out of build_order.txt; it is now built on OBS.
if has cloud-init; then ok "cloud-init present (version $(v cloud-init))"
else no "cloud-init absent"; fi

# pesign-obs-integration / dh-signobs used to exist only as a prebuilt .deb.
if has dh-signobs; then huh "dh-signobs installed in the image (build-time only, unexpected)"
else ok "dh-signobs not in the image (build-time only, as expected)"; fi

echo
echo "== 3. Kernel and dataplane =="
for p in linux-image-vyatta-amd64 vyatta-dataplane linux-perf-6.12 vplane-config; do
  if has "$p"; then ok "$p = $(v "$p")"; else huh "$p absent"; fi
done

# Which kernel the image BOOTS, not merely which it contains. Those are
# different questions, and checking only the first has already missed a real
# regression: the systemtap list asked for the linux-headers-amd64 metapackage,
# both DANOS and Debian ship a package by that name, and once trixie moved to
# 6.12.105-1 it outranked 6.12.101-1vyatta1. apt took Debian's headers and their
# linux-image with them, live-build made the newer kernel the default boot
# entry, and every manifest check still passed because the DANOS kernel was
# also present.
# Read the ISO itself, not the binary/ directory beside it. lb clean leaves
# binary/ in place, so a stale kernel there can differ from what was actually
# packaged -- in either direction.
kerns=$(xorriso -indev "$ISO" -find /live -name 'vmlinuz*' 2>/dev/null \
        | tr -d "'" | sed 's|.*/||' | grep -v '^vmlinuz$' | sort)
n_kern=$(printf '%s\n' "$kerns" | grep -c .)
if [ "$n_kern" -eq 0 ]; then
  huh "no kernel found under /live in the ISO"
else
  # /live/vmlinuz is the default boot entry; match it to a named kernel by size.
  # xorriso -lsl quotes the name, so strip quotes before comparing.
  boot_sz=$(xorriso -indev "$ISO" -lsl /live 2>/dev/null \
            | tr -d "'" | awk '$NF=="vmlinuz"{print $5}' | head -1)
  matched=$(xorriso -indev "$ISO" -lsl /live 2>/dev/null \
            | tr -d "'" | awk -v s="$boot_sz" '$5==s && $NF ~ /^vmlinuz-/ {print $NF}' | tr '\n' ' ')
  case "$matched" in
    *vyatta*) ok "default boot kernel is ${matched% }" ;;
    "")       huh "cannot identify the default boot kernel (size $boot_sz)" ;;
    *)        no "default boot kernel is ${matched% } -- expected the vyatta one" ;;
  esac
  if [ "$n_kern" -le 1 ]; then ok "one kernel in the ISO"
  else no "$n_kern kernels in the ISO: $(printf '%s ' $kerns)"; fi
fi

echo
echo "== 4. Retired forks really are Debian stock =="
# Each of these was a DANOS fork that has been retired in favour of Debian's
# package. A DANOS-built one carries a vyatta/danos version suffix, so the
# version string discriminates.
check_stock() {   # package  what it replaced
  local p=$1 note=$2 ver
  has "$p" || { huh "$p absent ($note)"; return; }
  ver=$(v "$p")
  case "$ver" in
    *vyatta*|*danos*) no "$p = $ver — still a DANOS build, expected Debian stock ($note)" ;;
    *) ok "$p = $ver — Debian stock ($note)" ;;
  esac
}
check_stock strongswan-charon   "was a DANOS fork"
check_stock libstrongswan       "was a DANOS fork"
check_stock chrony              "replaces the locally built NTP Classic"
check_stock libpcap0.8t64       "was a 1.8.1 fork"
check_stock inetutils-telnet    "replaces netkit-telnet"

# python3-vici is the one strongswan-related package that SHOULD be DANOS-built:
# Debian ships no vici python binding, so it is built from unmodified 6.0.1.
pv=$(v python3-vici)
case "$pv" in
  *danos*|*vyatta*) ok "python3-vici = $pv — DANOS-built, as intended (Debian has no vici binding)" ;;
  "")               no "python3-vici absent — the vici binding is not packaged by Debian" ;;
  *)                huh "python3-vici = $pv (expected a danos-suffixed build)" ;;
esac

echo
echo "== 5. Manifest sanity =="
dups=$(awk '{print $1}' "$MAN" | sort | uniq -d)
if [ -n "$dups" ]; then no "duplicate packages: $(echo "$dups" | tr '\n' ' ')"
else ok "no duplicate package names"; fi

n=$(grep -c . "$MAN")
if [ "$n" -gt 1200 ]; then ok "$n packages"
else huh "$n packages — fewer than expected (previous images had ~1505)"; fi

echo
printf '  %d passed, %d failed, %d warnings\n' "$pass" "$fail" "$warn"
[ "$fail" -eq 0 ]
