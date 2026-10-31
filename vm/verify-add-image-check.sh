#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-only
# `add system image` runs check_binary_signatures (vyatta-install-image.functions) on the image it is
# about to install before it copies anything. This runs the REAL function from the ISO under test on the
# ISO's real shim, GRUB and kernel, without booting anything, twice:
#
#   positive  with MOK support available   expect: success (rc 0)
#   negative  the same code, no mokutil    expect: fails at GRUB (rc 1, "no match in signature list for
#                                          .../grubx64.efi.signed"): shim is signed through the Microsoft
#                                          CA that is in db, GRUB and the kernel by the OBS certificate,
#                                          which is only a MOK
#
# The negative run is what makes the positive one mean something: the same function, the same files, the
# only difference is that nothing exports the MOK, and the answer flips.
#
# What is real and what is supplied. Real: the function text, sbverify, sig-list-to-certs, hexdump,
# openssl, and the three binaries, all from the ISO / the container. Supplied: the firmware state the
# function reads. efivarfs cannot be faked (efi-readvar and mokutil refuse a plain directory), so
# `efi-readvar -v db` is a stand-in that hands over Microsoft's db from OVMF_VARS_4M.ms.fd (the db the
# Secure Boot VMs use) and `mokutil --export` hands over the OBS signer certificate, as an enrolled MOK
# would; SecureBoot-<guid> is a file in a bind-mounted directory at the path the function hard-codes
# (/sys/firmware/efi/efivars, inside a privileged container only, the host's is untouched).
#
# This is NOT a test of signature validity. The function says so itself: it compares certificate
# subjects ("NOT cryptographic verification ... cannot detect a tampered binary").
#
# Usage: verify-add-image-check.sh <iso> <outdir> <virt-fw-vars>
# Output: <outdir>/results.txt (positive rc=N / negative rc=N), positive.out, negative.out, checksums.txt
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ISO=${1:?usage: verify-add-image-check.sh <iso> <outdir> <virt-fw-vars>}
OUT=${2:?outdir}
VFV=${3:?path to virt-fw-vars}
VARS_MS=${VARS_MS:-/usr/share/OVMF/OVMF_VARS_4M.ms.fd}
IMAGE=${CONTAINER_IMAGE:-debian:13-slim}
rm -rf "${OUT:?}"; mkdir -p "$OUT/root"
exec > >(tee "$OUT/add-image-check.log") 2>&1
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY

echo "== the chain's certificates"
python3 "$HERE/efi-inspect.py" "$ISO" "$OUT/inspect" > "$OUT/inspect.txt" || { echo "BLOCKED: efi-inspect failed"; exit 1; }
[ -s "$OUT/inspect/grubx64.signer.der" ] || { echo "BLOCKED: no signer certificate"; exit 1; }

echo "== the real files from the ISO's squashfs"
xorriso -osirrox on -indev "$ISO" -extract /live/filesystem.squashfs "$OUT/fs.squashfs" >/dev/null 2>&1 \
  || { echo "BLOCKED: cannot read /live/filesystem.squashfs"; exit 1; }
unsquashfs -q -f -d "$OUT/root" "$OUT/fs.squashfs" \
  usr/lib/shim/shimx64.efi.signed usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed \
  boot/vmlinuz boot/vmlinuz-6.12.0-trunk-vyatta-amd64 opt/vyatta/sbin/vyatta-install-image.functions >/dev/null \
  || { echo "BLOCKED: unsquashfs failed"; exit 1; }
rm -f "$OUT/fs.squashfs"
for f in usr/lib/shim/shimx64.efi.signed usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed boot/vmlinuz opt/vyatta/sbin/vyatta-install-image.functions; do
  [ -e "$OUT/root/$f" ] || { echo "BLOCKED: $f not in the image"; exit 1; }
done

echo "== the db the Secure Boot VMs have (OVMF_VARS_4M.ms.fd)"
"$VFV" -i "$VARS_MS" --output-json "$OUT/ms.json" >/dev/null 2>&1 || { echo "BLOCKED: virt-fw-vars failed"; exit 1; }
python3 - "$OUT/ms.json" "$OUT/db.esl" <<'PY' || { echo "BLOCKED: no db in the variable store"; exit 1; }
import json, sys
v = [x for x in json.load(open(sys.argv[1]))["variables"] if x["name"] == "db"][0]
open(sys.argv[2], "wb").write(bytes.fromhex(v["data"]))
print("db: %d bytes" % len(bytes.fromhex(v["data"])))
PY
( cd "$OUT" && sha256sum root/usr/lib/shim/shimx64.efi.signed root/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed \
    root/boot/vmlinuz-6.12.0-trunk-vyatta-amd64 root/opt/vyatta/sbin/vyatta-install-image.functions db.esl inspect/grubx64.signer.der ) | tee "$OUT/checksums.txt"

cat > "$OUT/drive.sh" <<'DRIVE'
#!/bin/bash
# runs inside the container: /w is the output directory
set -u
export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null 2>&1
apt-get install -y --no-install-recommends sbsigntool efitools openssl bsdextrautils >/dev/null 2>&1 \
  || { echo "BLOCKED: apt-get install failed"; exit 1; }
FV=/tmp/efivars; mkdir -p "$FV"
# attributes (4 bytes, little endian) then the value: SecureBoot = 1
printf '\x06\x00\x00\x00\x01' > "$FV/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
mount --bind "$FV" /sys/firmware/efi/efivars || { echo "BLOCKED: cannot bind the efivars directory"; exit 1; }
mkdir -p /stub/with-mok /stub/no-mok
cat > /stub/with-mok/efi-readvar <<'EOF'
#!/bin/sh
# efi-readvar -v db -o db : hand over the firmware db as <out>
[ "$1 $2" = "-v db" ] && [ "$3" = "-o" ] && cp /w/db.esl "$4"
EOF
cp /stub/with-mok/efi-readvar /stub/no-mok/efi-readvar
cat > /stub/with-mok/mokutil <<'EOF'
#!/bin/sh
# mokutil --export : the enrolled MOK, as MOK-0001.der in the current directory
[ "$1" = "--export" ] && cp /w/inspect/grubx64.signer.der MOK-0001.der
exit 0
EOF
chmod +x /stub/*/*
ROOT=/w/root
FUNCS=$ROOT/opt/vyatta/sbin/vyatta-install-image.functions
run() {   # run <name> <stubdir>
  ( export PATH="$2:$PATH"
    # shellcheck disable=SC1090
    . "$FUNCS" >/dev/null 2>&1
    type check_binary_signatures >/dev/null 2>&1 || { echo "BLOCKED: check_binary_signatures not defined by $FUNCS"; exit 99; }
    out=$(check_binary_signatures "$ROOT" 2>&1); rc=$?
    printf '%s\n' "$out" > "/w/$1.out"
    echo "$1 rc=$rc" >> /w/results.txt
    echo "$1: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /' )
}
: > /w/results.txt
echo "mokutil on PATH for the positive run: $(PATH=/stub/with-mok:$PATH command -v mokutil)"
echo "mokutil on PATH for the negative run: $(PATH=/stub/no-mok:/usr/bin:/bin command -v mokutil || echo none)"
run positive /stub/with-mok
run negative /stub/no-mok
DRIVE
chmod +x "$OUT/drive.sh"
echo "== inside a privileged $IMAGE container"
docker run --rm --network host --privileged -v "$OUT:/w" "$IMAGE" bash /w/drive.sh
rc=$?
chown -R "$(id -u):$(id -g)" "$OUT" 2>/dev/null || docker run --rm -v "$OUT:/w" "$IMAGE" chown -R "$(id -u):$(id -g)" /w
echo "container exit status $rc"
exit "$rc"
