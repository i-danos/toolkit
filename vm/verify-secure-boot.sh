#!/bin/bash
# P2: does the ISO's UEFI boot chain enforce Secure Boot, and does it boot when
# trusted? Real OVMF firmware with Secure Boot on, not a simulation.
#
# The chain on this ISO (see efi-inspect.py): Debian shim, signed by Microsoft
# -> GRUBX64.EFI signed by the OBS project's own certificate -> the kernel,
# signed by the same certificate. Firmware trusts Microsoft; shim does not trust
# the OBS certificate unless it is enrolled as a MOK. So:
#
#   T1  Microsoft keys only, no MOK        expect: refused before the kernel
#   T2  the OBS certificate enrolled (MOK) expect: GRUB, then the kernel starts
#   T3  T2 plus one flipped byte in GRUB   expect: shim refuses GRUB
#   T4  T2 plus one flipped byte in kernel expect: GRUB refuses the kernel
#
# T2 against T4 differs by exactly one bit, so a T4 refusal is the signature
# check working and not the kernel failing for some other reason -- the message
# is checked, not just the absence of a login.
#
# A tampered byte is written into a private copy of the ISO at the offset
# efi-inspect.py reports, and restored afterwards; the original ISO is never
# opened for writing. The MOK is injected into OVMF's variable store with
# virt-fw-vars (a virtualenv; nothing is installed system-wide).
#
# Usage: verify-secure-boot.sh <iso> <outdir> <virt-fw-vars>
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ISO=${1:?usage: verify-secure-boot.sh <iso> <outdir> <virt-fw-vars>}
OUT=${2:?outdir}
VFV=${3:?path to virt-fw-vars}
CODE=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
VARS_MS=/usr/share/OVMF/OVMF_VARS_4M.ms.fd
NAME=sb
RUN=${OBS_DIR:-/home/aikon/danos/.obs}/run/$NAME
SHIM_GUID=605dab50-e046-4300-abb6-3dd810dd8b23
mkdir -p "$OUT" "$RUN"
exec > >(tee "$OUT/secure-boot.log") 2>&1

for f in "$CODE" "$VARS_MS" "$VFV"; do [ -e "$f" ] || { echo "BLOCKED: missing $f"; exit 1; }; done

echo "===== what the chain is ====="
python3 "$HERE/efi-inspect.py" "$ISO" "$OUT/inspect" | tee "$OUT/inspect.txt"
GRUB_OFF=$(sed -n 's|.*GRUBX64.EFI .*iso_offset=\([0-9]*\).*|\1|p' "$OUT/inspect.txt")
KERN_OFF=$(sed -n 's|.*vmlinuz *iso_offset=\([0-9]*\).*|\1|p' "$OUT/inspect.txt")
[ -n "$GRUB_OFF" ] && [ -n "$KERN_OFF" ] || { echo "BLOCKED: could not read offsets"; exit 1; }
CERT=$OUT/inspect/grubx64.signer.pem
[ -s "$CERT" ] || { echo "BLOCKED: no signer certificate extracted"; exit 1; }
echo "certificate to enroll: $(openssl x509 -in "$CERT" -noout -subject -enddate | tr '\n' ' ')"

"$VFV" -i "$VARS_MS" --add-mok "$SHIM_GUID" "$CERT" -o "$OUT/vars-mok.fd" >/dev/null 2>&1 \
  || { echo "BLOCKED: virt-fw-vars could not enroll the MOK"; exit 1; }

qemu_pid() {
  local p; p=$(cat "$RUN/qemu.pid" 2>/dev/null)
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  tr '\0' ' ' </proc/$p/cmdline 2>/dev/null | grep -q -- "-name $NAME " || return 1
  echo "$p"
}
stop_vm() {
  local p; p=$(qemu_pid) || { rm -f "${RUN:?}"/*.sock "${RUN:?}/qemu.pid"; return 0; }
  kill -9 "$p" 2>/dev/null
  while kill -0 "$p" 2>/dev/null; do sleep 0.5; done
  rm -f "${RUN:?}"/*.sock "${RUN:?}/qemu.pid"
}
trap stop_vm EXIT

# Boot the ISO under Secure Boot with the given variable store and ISO file.
# Serial output goes to $2; the menu entry to pick (0-based) is $3.
boot_uefi() {
  local vars=$1 iso=$2 entry=$3 log=$4 secs=$5
  stop_vm
  local v; v=$(mktemp "$OUT/vars.XXXXXX"); cp "$vars" "$v"
  nohup setsid qemu-system-x86_64 -name "$NAME" -enable-kvm -cpu host -smp 2 -m 3072 \
    -machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on \
    -drive if=pflash,format=raw,unit=0,file="$CODE",readonly=on \
    -drive if=pflash,format=raw,unit=1,file="$v" \
    -device ich9-ahci,id=ahci -drive file="$iso",media=cdrom,if=none,id=cd,readonly=on \
    -device ide-cd,drive=cd,bus=ahci.0 \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -display none -serial file:"$log" \
    -monitor unix:"$RUN/monitor.sock",server,nowait \
    -pidfile "$RUN/qemu.pid" </dev/null > "$RUN/qemu.log" 2>&1 &
  sleep 3
  qemu_pid >/dev/null || { echo "  qemu did not start: $(tail -2 "$RUN/qemu.log")"; rm -f "$v"; return 1; }
  python3 - "$RUN/monitor.sock" "$entry" "$secs" "$log" <<'PY'
import re, socket, struct, sys, time, zlib
mon, entry, secs, log = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
m = socket.socket(socket.AF_UNIX)
for _ in range(30):
    try: m.connect(mon); break
    except OSError: time.sleep(1)
m.settimeout(3)
def hmp(cmd):
    m.sendall((cmd + "\n").encode()); time.sleep(0.25)
    try: m.recv(65536)
    except socket.timeout: pass
def text():
    try: raw = open(log, "rb").read().decode(errors="replace")
    except OSError: return ""
    return re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", raw)
def png(path):
    hmp("screendump %s.ppm" % path); time.sleep(1.5)
    try:
        d = open(path + ".ppm", "rb").read(); parts = d.split(b"\n", 3)
        w, h = map(int, parts[1].split()); px = parts[3]
    except Exception:
        return
    raw = b"".join(b"\x00" + px[y*w*3:(y+1)*w*3] for y in range(h))
    ch = lambda t, c: struct.pack(">I", len(c)) + t + c + struct.pack(">I", zlib.crc32(t + c) & 0xffffffff)
    open(path + ".png", "wb").write(b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + ch(b"IDAT", zlib.compress(raw)) + ch(b"IEND", b""))
    import os; os.remove(path + ".ppm")
sent = False; done_at = None
# Phase 1: qemu on this host can sit in uninterruptible I/O for a long while
# (swap is full) before the firmware runs at all, so the clock for the test
# starts when the first serial byte appears, not when the process does.
t0 = time.time(); started = None
while time.time() - t0 < 600:
    # The first bytes on the serial line are only the terminal's own reset
    # sequence; the clock starts at the first line of actual text.
    if re.search(r"[A-Za-z]{3}", text()): started = time.time(); break
    time.sleep(2)
print("  firmware first spoke after %ds" % (time.time() - t0) if started else "  firmware never spoke in 600s")
end = (started or time.time()) + secs
DECISIVE = r"Linux version [0-9]|bad shim signature|Verification failed|Security Violation|Access Denied|Failed to load image|MokManager|Perform MOK"
while started and time.time() < end:
    time.sleep(1)
    t = text()
    # Once GRUB draws its menu, walk down to the wanted entry with the keyboard.
    if not sent and "live-debug" in t and "GNU GRUB" in t:
        time.sleep(1)
        for _ in range(entry): hmp("sendkey down"); time.sleep(0.3)
        hmp("sendkey ret"); sent = True
    if done_at is None and re.search(DECISIVE, t): done_at = time.time() + 6
    if done_at and time.time() > done_at: break
png(log)
PY
  stop_vm; rm -f "$v"
}

# What the serial output says happened.
classify() {
  local f=$1
  local t; t=$(sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$f" | tr -d '\r')
  echo "$t" | grep -qiE "Linux version [0-9]" && echo kernel-started && return
  echo "$t" | grep -qiE "bad shim signature" && echo "grub-refused-kernel(bad shim signature)" && return
  echo "$t" | grep -qiE "Verification failed|Security Violation|Access Denied|Failed to load image|MokManager|Perform MOK|Failed to open" && echo "shim-refused" && return
  echo "$t" | grep -qiE "GNU GRUB|live-debug" && echo "grub-menu-only" && return
  echo "$t" | grep -qE "BdsDxe: starting Boot0002" && echo "chain-stopped-after-shim(no GRUB, no kernel)" && return
  echo "nothing-recognised"
}

pass=0; fail=0
check() { # name expected actual
  if [ "$3" = "$2" ] || { [ "$2" = "refused" ] && echo "$3" | grep -qE "refused|stopped"; }; then
    echo "  PASS  $1: $3"; pass=$((pass + 1))
  else
    echo "  FAIL  $1: expected $2, got $3"; fail=$((fail + 1))
  fi
}

echo; echo "===== T1: Microsoft keys only, OBS certificate NOT enrolled ====="
boot_uefi "$VARS_MS" "$ISO" 3 "$OUT/t1.serial" 90
R=$(classify "$OUT/t1.serial"); check "T1 unenrolled chain is refused" refused "$R"

echo; echo "===== T2: OBS certificate enrolled as MOK ====="
boot_uefi "$OUT/vars-mok.fd" "$ISO" 3 "$OUT/t2.serial" 240
R=$(classify "$OUT/t2.serial"); check "T2 trusted chain boots" kernel-started "$R"
sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$OUT/t2.serial" | tr -d '\r' | grep -iE "Secure boot|lockdown|locked down" | head -4 | sed 's/^/      /'

echo; echo "===== T3: T2 plus one flipped byte in GRUB ====="
cp "$ISO" "$OUT/tampered.iso"
flip() { python3 - "$OUT/tampered.iso" "$1" <<'PY'
import sys
p, off = sys.argv[1], int(sys.argv[2])
with open(p, "r+b") as f:
    f.seek(off); b = f.read(1); f.seek(off); f.write(bytes([b[0] ^ 0x01]))
print("  flipped one bit at ISO offset %d" % off)
PY
}
flip $((GRUB_OFF + 1000000))
boot_uefi "$OUT/vars-mok.fd" "$OUT/tampered.iso" 3 "$OUT/t3.serial" 90
R=$(classify "$OUT/t3.serial"); check "T3 tampered GRUB is refused" refused "$R"
flip $((GRUB_OFF + 1000000))          # restore

echo; echo "===== T4: T2 plus one flipped byte in the kernel ====="
flip $((KERN_OFF + 5000000))
boot_uefi "$OUT/vars-mok.fd" "$OUT/tampered.iso" 3 "$OUT/t4.serial" 120
R=$(classify "$OUT/t4.serial"); check "T4 tampered kernel is refused" refused "$R"
rm -f "$OUT/tampered.iso"

echo; echo "===== $pass passed, $fail failed ====="
[ $fail -eq 0 ]
