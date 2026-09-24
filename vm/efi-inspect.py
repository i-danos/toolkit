#!/usr/bin/env python3
"""What is the UEFI boot chain on this ISO, and who signed each link?

Usage: efi-inspect.py <iso> <outdir>
       efi-inspect.py --fat <raw-fat-image> <outdir>

With --fat the input is a raw FAT filesystem (an ESP cut out of an installed
disk, e.g. with `qemu-img dd -f qcow2 -O raw bs=1M skip=1 count=512 if=disk of=esp.raw`)
instead of an ISO; the kernel step is skipped and iso_offset is the offset
inside that image.

Extracts the ISO's El Torito UEFI image (a FAT filesystem embedded in the ISO,
which needs no root and no mtools to read -- a small FAT12/16 reader is included
so this runs anywhere xorriso and sbverify do), writes every file in it under
<outdir>/esp/, pulls the Authenticode signer certificate out of each .EFI file
into <outdir>/<name>.signer.{pem,der}, and prints one line per file with the
signature issuer as sbverify reports it.

It also prints, for the two places a tamper test needs to write, the byte offset
inside the ISO: the ESP file data (so a byte can be flipped in place, with no
image rebuild) and /live/vmlinuz.
"""
import os
import re
import struct
import subprocess
import sys

FAT_ONLY = sys.argv[1] == "--fat"
if FAT_ONLY:
    iso, out = sys.argv[2], sys.argv[3]
else:
    iso, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)


def sh(*a):
    return subprocess.run(a, capture_output=True, text=True)


if FAT_ONLY:
    esp_off, esp_size = 0, os.path.getsize(iso)
    img = open(iso, "rb").read()
else:
    # Where the UEFI image sits in the ISO and how big it is.
    r = sh("xorriso", "-osirrox", "on", "-indev", iso, "-extract_boot_images", out + "/bi/")
    m = re.search(r"eltorito_img\d+_uefi\.img : offset=(\d+) size=(\d+)", r.stdout + r.stderr)
    if not m:
        sys.exit("no UEFI El Torito image found in %s" % iso)
    esp_off, esp_size = int(m.group(1)), int(m.group(2))
    img = open([os.path.join(out, "bi", f) for f in os.listdir(out + "/bi") if "uefi" in f][0], "rb").read()

bps, spc, rsv, nfat, rootent, tot16, _, spf = struct.unpack_from("<HBHBHHBH", img, 11)
tot = tot16 or struct.unpack_from("<I", img, 32)[0]
root_start = (rsv + nfat * spf) * bps
root_sz = rootent * 32
data_start = root_start + root_sz
fat = img[rsv * bps:(rsv + spf) * bps]
fat16 = ((tot - data_start // bps) // spc) >= 4085


def nxt(c):
    if fat16:
        return struct.unpack_from("<H", fat, c * 2)[0]
    v = struct.unpack_from("<H", fat, c * 3 // 2)[0]
    return (v >> 4) if c & 1 else (v & 0xfff)


def chain(c):
    res = []
    while 2 <= c < (0xfff0 if fat16 else 0xff0):
        res.append(c)
        c = nxt(c)
    return res


def read_chain(c, size=None):
    b = b"".join(img[data_start + (x - 2) * spc * bps: data_start + (x - 1) * spc * bps] for x in chain(c))
    return b[:size] if size is not None else b


def entries(raw):
    lfn = ""
    for i in range(0, len(raw), 32):
        e = raw[i:i + 32]
        if e[0] == 0:
            break
        if e[0] == 0xE5:
            lfn = ""
            continue
        if e[11] == 0x0F:
            part = (e[1:11] + e[14:26] + e[28:32]).decode("utf-16le")
            lfn = part.split("\x00")[0].split("￿")[0] + lfn
            continue
        name, ext = e[:8].decode("latin1").strip(), e[8:11].decode("latin1").strip()
        yield (lfn or name + ("." + ext if ext else "")), bool(e[11] & 0x10), \
            struct.unpack_from("<H", e, 26)[0], struct.unpack_from("<I", e, 28)[0]
        lfn = ""


files = {}


def walk(raw, path):
    for n, isdir, cl, sz in entries(raw):
        if n in (".", ".."):
            continue
        full = path + "/" + n
        if isdir:
            walk(read_chain(cl), full)
        else:
            os.makedirs(out + "/esp" + path, exist_ok=True)
            data = read_chain(cl, sz)
            open(out + "/esp" + full, "wb").write(data)
            # Byte offset of this file's first cluster inside the ISO, assuming
            # it is stored contiguously (true for a freshly written image).
            # An empty file has no cluster chain at all.
            first = chain(cl)
            files[full] = ((esp_off + data_start + (first[0] - 2) * spc * bps) if first else None, sz)


walk(img[root_start:root_start + root_sz], "")


def signer(path, tag):
    d = open(path, "rb").read()
    pe = struct.unpack_from("<I", d, 0x3c)[0]
    opt = pe + 24
    dd = opt + (112 if struct.unpack_from("<H", d, opt)[0] == 0x20b else 96)
    off, size = struct.unpack_from("<II", d, dd + 32)
    if not off:
        return None
    open(out + "/" + tag + ".p7s", "wb").write(d[off + 8:off + size])
    sh("openssl", "pkcs7", "-inform", "DER", "-in", out + "/" + tag + ".p7s",
       "-print_certs", "-out", out + "/" + tag + ".signer.pem")
    sh("openssl", "x509", "-in", out + "/" + tag + ".signer.pem", "-outform", "DER",
       "-out", out + "/" + tag + ".signer.der")
    v = sh("sbverify", "--list", path).stdout
    iss = re.search(r"image signature issuers:\n - (.*)", v)
    return iss.group(1) if iss else "(unparsed)"


print("UEFI image at ISO offset %d, %d bytes" % (esp_off, esp_size))
for f, (o, sz) in sorted(files.items()):
    if o is None:
        print("  %-22s %8d bytes  (empty)" % (f, sz))
    elif f.upper().endswith(".EFI"):
        tag = os.path.basename(f).replace(".EFI", "").lower()
        print("  %-22s %8d bytes  iso_offset=%-9d signer: %s" % (f, sz, o, signer(out + "/esp" + f, tag)))
    else:
        print("  %-22s %8d bytes  (not a PE image)" % (f, sz))

if FAT_ONLY:
    sys.exit(0)

# The kernel, to be verified the same way.
k = sh("xorriso", "-osirrox", "on", "-indev", iso, "-extract", "/live/vmlinuz", out + "/vmlinuz")
rep = sh("xorriso", "-indev", iso, "-find", "/live/vmlinuz", "-exec", "report_lba").stdout
lba = re.search(r"File data lba:\s*\d+\s*,\s*(\d+)\s*,", rep)
print("  /live/vmlinuz          %8d bytes  signer: %s" % (os.path.getsize(out + "/vmlinuz"), signer(out + "/vmlinuz", "vmlinuz")))
if lba:
    print("  /live/vmlinuz          iso_offset=%d" % (int(lba.group(1)) * 2048))
