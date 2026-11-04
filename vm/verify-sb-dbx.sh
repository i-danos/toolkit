#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-only
# signed_boot_chain_dbx on EDK2/OVMF (NOT a physical machine's UEFI): does the firmware refuse a shim whose hash is in dbx?
#   c1 control  : Microsoft keys + OBS MOK, empty dbx            -> the ISO boots to "Linux version" (so the chain itself is fine)
#   c2 revoked  : same variable store + dbx entry = the Authenticode SHA-256 of the ISO's shim (BOOTX64.EFI)
#                                                                -> the firmware refuses to load the shim: no GRUB, no kernel
#   c3 decoy    : same + a dbx entry with a DIFFERENT SHA-256    -> boots like c1 (the refusal in c2 is about that hash, not about dbx existing)
# The hash is computed here (PE Authenticode: everything except the checksum, the certificate-table entry and the certificate table)
# and cross-checked against the digest inside the shim's own PKCS#7 signature, so "the hash we revoked" is the hash the firmware computes.
# KVM, -cpu host (uefi-vm.sh); one QEMU at a time; every wait capped; a trap kills the guest.
#
# Usage: verify-sb-dbx.sh <iso> <outdir> <virt-fw-vars>
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ISO=${1:?iso}; OUT=${2:?outdir}; VFV=${3:?virt-fw-vars}
. "$HERE/sb-lib.sh"
sb_init sbdbx "${SBDBX_PORT:-2274}"
if sb_other_qemu; then echo "REFUSED: another qemu-system is running"; exit 2; fi
mkdir -p "$OUT"; : > "$OUT/results.txt"
R() { echo "$*" >> "$OUT/results.txt"; }
echo "qemu: -enable-kvm -cpu host -smp 2 -m 3072 -machine q35,smm=on, OVMF secboot (edk2), not a physical UEFI"
R "iso_sha256=$(sha256sum "$ISO" | cut -d' ' -f1)"
R "firmware=edk2/OVMF (a virtual machine's firmware); this is NOT the UEFI of a physical machine"
R "ovmf=$(dpkg-query -W -f='${Package} ${Version}' ovmf 2>/dev/null)"
R "ovmf_code=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.secboot.fd} sha256=$(sha256sum "${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.secboot.fd}" | cut -d' ' -f1)"
R "virt-fw-vars=$("$VFV" --version 2>&1 | head -1)"
R "qemu=$(qemu-system-x86_64 --version | head -1)"

bash "$HERE/sb-make-vars.sh" "$ISO" "$OUT" "$VFV" > "$OUT/make-vars.out" 2>&1 || { R "STAGE vars FAIL"; exit 3; }
SHIM="$OUT/inspect/esp/EFI/BOOT/BOOTX64.EFI"
[ -s "$SHIM" ] || { R "STAGE shim FAIL no $SHIM"; exit 3; }
cp "$SHIM" "$OUT/shim-BOOTX64.EFI"
HASH=$(python3 - "$SHIM" <<'PY'
import hashlib, struct, sys
b = open(sys.argv[1], "rb").read()
pe = struct.unpack_from("<I", b, 0x3c)[0]
assert b[pe:pe+4] == b"PE\0\0"
opt = pe + 24
magic = struct.unpack_from("<H", b, opt)[0]
cksum = opt + 64                                          # CheckSum
cert_dir = opt + (112 if magic == 0x20b else 96) + 4 * 8   # data directory 4: the certificate table's file offset + size
cert_off, cert_size = struct.unpack_from("<II", b, cert_dir)
end = cert_off if cert_off else len(b)
# Authenticode digest of a PE whose sections are contiguous (this shim's are, and the result is checked against the
# signature's own digest below): the file without the checksum, the certificate-table entry and the certificate table
print(hashlib.sha256(b[:cksum] + b[cksum+4:cert_dir] + b[cert_dir+8:end]).hexdigest())
PY
)
# the digest the shim's own signature carries (first 32-byte OCTET STRING of the PKCS#7: SpcIndirectDataContent)
SIGHASH=$(openssl asn1parse -inform DER -in "$OUT/inspect/bootx64.p7s" 2>/dev/null | grep -a 'l=  32 prim: OCTET STRING' | head -1 | sed 's/.*HEX DUMP\]://' | tr 'A-F' 'a-f')
R "signature-digest=$SIGHASH"
if [ "$HASH" != "$SIGHASH" ]; then R "STAGE hash FAIL computed=$HASH signature=$SIGHASH"; exit 3; fi
R "shim-file=BOOTX64.EFI sha256_file=$(sha256sum "$SHIM" | cut -d' ' -f1)"
R "shim-authenticode-sha256=$HASH"
R "hash-in-signature=yes"
python3 - "$HASH" > "$OUT/decoy.hash" <<'PY'
import hashlib, sys
print(hashlib.sha256(b"not the shim " + sys.argv[1].encode()).hexdigest())
PY
OWNER=77fa9abd-0359-4d32-bd60-28f4e78f784b            # Microsoft vendor GUID, the owner field only
"$VFV" -i "$OUT/vars.fd" --add-dbx-hash "$OWNER" "$HASH" -o "$OUT/vars-revoked.fd" > "$OUT/vars-revoked.out" 2>&1 || { R "STAGE dbx-vars FAIL"; cat "$OUT/vars-revoked.out"; exit 3; }
"$VFV" -i "$OUT/vars.fd" --add-dbx-hash "$OWNER" "$(cat "$OUT/decoy.hash")" -o "$OUT/vars-decoy.fd" > "$OUT/vars-decoy.out" 2>&1 || { R "STAGE decoy-vars FAIL"; exit 3; }
# what the three variable stores really hold in dbx (read back from the files, not from what was asked for)
for f in vars.fd vars-revoked.fd vars-decoy.fd; do "$VFV" -i "$OUT/$f" --output-json "$OUT/$f.json" >/dev/null 2>&1; done
python3 - "$OUT" "$HASH" "$(cat "$OUT/decoy.hash")" >> "$OUT/results.txt" <<'PY'
import json, sys
out, shim, decoy = sys.argv[1:4]
for f in ("vars.fd", "vars-revoked.fd", "vars-decoy.fd"):
    v = [x for x in json.load(open("%s/%s.json" % (out, f)))["variables"] if x["name"] == "dbx"][0]
    raw = bytes.fromhex(v["data"])
    print("dbx %s bytes=%d has-shim-hash=%d has-decoy-hash=%d" % (f, len(raw), int(bytes.fromhex(shim) in raw), int(bytes.fromhex(decoy) in raw)))
PY

# boot the ISO with <vars>; wait for a decisive line; keep the serial log
boot() {   # boot <name> <vars.fd> <seconds>
  local n=$1 v=$2 secs=$3
  cp "$v" "$OUT/run-$n.fd"
  "$HERE/uefi-vm.sh" start "$SB_NAME" "$OUT/run-$n.fd" "$SB_PORT" --cdrom "$ISO" || { R "$n start FAIL"; return 1; }
  ( timeout "$secs" "$HERE/grub-pick.py" "$SB_RUN" 2 --wait "$secs" > "$OUT/grub-pick-$n.out" 2>&1 & ) 
  local end=$(( $(date +%s) + secs )) res=timeout
  while [ "$(date +%s)" -lt "$end" ]; do
    local t; t=$(sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$SB_RUN/serial.log" 2>/dev/null | tr -d '\r')
    if echo "$t" | grep -qE 'node login:'; then res=booted; break; fi        # the whole chain ran: shim, GRUB, kernel, userspace
    if echo "$t" | grep -qiE 'Access Denied|Security Violation|Verification failed|Failed to load image'; then res=refused; sleep 5; break; fi
    sleep 2
  done
  R "$n result=$res"
  cp "$SB_RUN/serial.log" "$OUT/serial-$n.log"
  "$HERE/uefi-vm.sh" stop "$SB_NAME" >/dev/null 2>&1
}
boot c1 "$OUT/vars.fd" 300
boot c2 "$OUT/vars-revoked.fd" 120
boot c3 "$OUT/vars-decoy.fd" 300
exit 0
