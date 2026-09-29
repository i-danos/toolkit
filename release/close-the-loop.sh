#!/bin/bash
# Close the loop the 2026-09-28 evaluation asked for:
#
#   OBS all-green confirmation -> immutable R2 snapshot -> containerized ISO
#   -> QEMU acceptance -> provenance archive
#
# Each stage refuses to proceed on a check that failed instead of hoping a
# later stage catches it. Three real incidents drove that: a stale R2 CDN
# cache that kept serving an old package index after a correct re-upload, an
# OBS "blocked" package that does not reschedule itself once its dependency
# reappears, and a libpcap epoch bump that broke a home-grown Makefile version
# regex -- all three looked like a different stage's problem until traced one
# level further. See the danos-r2-containerized-iso-flow memory for the full
# writeups; this script encodes the fixes as preconditions instead of retelling
# the stories.
#
# Usage: close-the-loop.sh [snapshot-ts]
#   snapshot-ts defaults to the current UTC time. Every run gets its own R2
#   path -- see "immutable" above -- so passing one in is only for resuming a
#   run that died after the snapshot was already uploaded.
set -Eeuo pipefail

OBS_DIR=${OBS_DIR:-/home/aikon/danos/.obs}
OSC="setsid --wait $OBS_DIR/osc -A https://api.opensuse.org"
PRJ=home:i-danos
REPO=2608
ARCH=x86_64
SRC=/home/aikon/danos/build-iso/danos-sources
BUILD_ISO_DIR="$SRC/build-iso"
VERIFY_CONTAINER=${VERIFY_CONTAINER:-danos-2110b-build}
R2_BUCKET=aikon-r2
R2_DOMAIN=https://r2.aikon.qzz.io
R2_PREFIX_BASE="danos-apt/$REPO/snapshots"
WORK=${WORK:-/tmp/close-the-loop}
# Packages that are intentionally disabled in project-meta.xml, not build
# failures. Anything blocked/broken/unresolvable/failed that is NOT in this
# list stops the run at stage 1.
DISABLED_ALLOWLIST="golang-dbus golang-defaults golang-golang-x-sys vplane-config-npf-alg-scripts"

TS=${1:-$(date -u +%Y%m%dT%H%M%SZ)}
PREFIX="$R2_PREFIX_BASE/$TS"
mkdir -p "$WORK"
LOCAL_REPO="$WORK/repo"
mkdir -p "$LOCAL_REPO"

echo "== close-the-loop: snapshot $TS =="

# ---- stage 0: OBS session sanity ----
# An expired osc session answers every query empty, which reads as "every
# package missing" rather than "cannot see OBS at all" -- refuse up front
# instead of producing that false catastrophe. See check-obs-current.sh.
if ! timeout 30 $OSC api "/source/$PRJ" < /dev/null > /dev/null 2>&1; then
	echo "Cannot reach $PRJ: the osc session has expired." >&2
	echo "    $OBS_DIR/osc -A https://api.opensuse.org api /person/i-danos > /dev/null && echo OK" >&2
	exit 1
fi

# ---- stage 1: OBS all-green confirmation ----
echo "-- stage 1: OBS all-green --"
result_xml=$($OSC api "/build/$PRJ/_result?repository=$REPO&arch=$ARCH" < /dev/null)
manifest_json=$(python3 - "$result_xml" "$DISABLED_ALLOWLIST" <<'PYEOF'
import sys, xml.etree.ElementTree as ET, json

xml_text, allowlist_str = sys.argv[1], sys.argv[2]
allowlist = set(allowlist_str.split())
root = ET.fromstring(xml_text)

packages = {}
bad = []
for status in root.iter('status'):
    name = status.get('package')
    code = status.get('code')
    details_el = status.find('details')
    details = details_el.text if details_el is not None else None
    ok = code == 'succeeded' or (code == 'finished' and details == 'succeeded')
    disabled = code == 'disabled'
    packages[name] = {'code': code, 'details': details}
    if not ok and not disabled:
        bad.append(f"{name}: code={code} details={details}")
    elif disabled and name not in allowlist:
        bad.append(f"{name}: disabled but not in the allowlist -- was this intentional?")

if bad:
    print("NOT GREEN:", file=sys.stderr)
    for b in bad:
        print(f"  {b}", file=sys.stderr)
    sys.exit(1)

succeeded = sorted(n for n, v in packages.items() if v['code'] != 'disabled')
disabled_here = sorted(n for n, v in packages.items() if v['code'] == 'disabled')
print(json.dumps({
    'obs_state': root.find('result').get('state') if root.find('result') is not None else None,
    'succeeded_count': len(succeeded),
    'succeeded': succeeded,
    'disabled': disabled_here,
}))
PYEOF
) || { echo "OBS is not fully green -- fix the listed packages before re-running." >&2; exit 1; }

succeeded_count=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['succeeded_count'])" "$manifest_json")
echo "   $succeeded_count packages succeeded, rest disabled by design"
echo "$manifest_json" > "$WORK/obs-manifest.json"

# ---- stage 2: sync binaries from OBS ----
echo "-- stage 2: sync binaries (idempotent, only fetches what's missing/changed) --"
python3 -c "import json; print('\n'.join(json.load(open('$WORK/obs-manifest.json'))['succeeded']))" \
  > "$WORK/package-list.txt"
while read -r pkg; do
	[ -n "$pkg" ] || continue
	# osc getbinaries hits transient connection resets under back-to-back
	# sequential calls (IncompleteRead on the OBS side, seen before on large
	# source tarballs -- see danos-r2-containerized-iso-flow); a fixed-count
	# retry here fixed every occurrence observed so far, and getbinaries is
	# idempotent so a retry never duplicates or corrupts anything already
	# downloaded.
	ok=false
	for attempt in 1 2 3; do
		if $OSC getbinaries "$PRJ" "$pkg" "$REPO" "$ARCH" -d "$LOCAL_REPO" < /dev/null > /dev/null 2>&1; then
			ok=true
			break
		fi
		sleep 2
	done
	$ok || echo "   warning: getbinaries failed for $pkg after 3 attempts, will show up as missing below" >&2
done < "$WORK/package-list.txt"

deb_count=$(find "$LOCAL_REPO" -maxdepth 1 -name '*.deb' | wc -l)
echo "   $deb_count .deb files present locally"

# Cross-check against OBS's own authoritative per-package file listing. A
# partial download here produced exactly the "Unable to locate package" ISO
# failure this script exists to prevent, and it fails silently -- osc's retry
# logic does not always flag it. See danos-r2-containerized-iso-flow.
missing=0
while read -r pkg; do
	[ -n "$pkg" ] || continue
	# `|| true`: grep exits 1 on zero matches (not an error, but nonzero), and
	# under set -e a failing command substitution inside an assignment kills
	# the whole script right here -- silently, same as the xargs/set -e bug
	# in stage 3's upload loop. A package that genuinely has zero .deb
	# binaries is implausible, but a transient osc api hiccup producing empty
	# output isn't, and this check is a secondary safety net on top of stage
	# 2's own getbinaries retries -- skipping one package's cross-check on a
	# hiccup is a far smaller cost than losing the whole run with no error.
	expected=$($OSC api "/build/$PRJ/_result?package=$pkg&repository=$REPO&arch=$ARCH&view=binarylist" \
		< /dev/null 2>/dev/null | grep -oE 'filename="[^"]+\.deb"' | sed 's/filename="//; s/"$//') || true
	while read -r f; do
		[ -n "$f" ] || continue
		[ -f "$LOCAL_REPO/$f" ] || { echo "   MISSING: $f (from $pkg)" >&2; missing=$((missing + 1)); }
	done <<< "$expected"
done < "$WORK/package-list.txt"

if [ "$missing" -gt 0 ]; then
	echo "$missing file(s) missing after sync -- re-run stage 2 (osc getbinaries is idempotent)." >&2
	exit 1
fi
echo "   verified complete against OBS's binarylist"

# ---- stage 3: regenerate apt indices, upload immutable snapshot ----
echo "-- stage 3: build indices, upload to a fresh R2 snapshot --"
docker exec "$VERIFY_CONTAINER" rm -rf /tmp/close-loop-repo
docker cp "$LOCAL_REPO" "$VERIFY_CONTAINER:/tmp/close-loop-repo"
docker exec "$VERIFY_CONTAINER" bash -c '
  set -e
  cd /tmp/close-loop-repo
  dpkg-scanpackages --multiversion . /dev/null > Packages 2>/tmp/scan-err.log
  gzip -9 -c Packages > Packages.gz
  xz -9 -c Packages > Packages.xz
  cat > /tmp/close-loop-ftparchive.conf <<CONF
Dir { ArchiveDir "/tmp/close-loop-repo"; };
Default { Packages::Compress ". gzip xz"; };
APT::FTPArchive::Release::Codename "'"$REPO"'";
APT::FTPArchive::Release::Suite "'"$REPO"'";
APT::FTPArchive::Release::Label "DANOS '"$REPO"'";
APT::FTPArchive::Release::Origin "DANOS";
APT::FTPArchive::Release::Architectures "amd64";
APT::FTPArchive::Release::Components "main";
APT::FTPArchive::Release::Description "DANOS '"$REPO"' - home:i-danos OBS repository mirror";
CONF
  apt-ftparchive -c /tmp/close-loop-ftparchive.conf release . > Release
'
rm -rf "$WORK/apt-final"
docker cp "$VERIFY_CONTAINER:/tmp/close-loop-repo" "$WORK/apt-final"

upload_one() {
	f="$1"
	ct="${2:-application/vnd.debian.binary-package}"
	for attempt in 1 2 3; do
		npx wrangler r2 object put "$R2_BUCKET/$PREFIX/$f" --file "$f" --content-type "$ct" --remote \
			> "/tmp/close-loop-upload-$$.log" 2>&1 && return 0
		sleep 2
	done
	echo "FAIL $f" >> "$WORK/upload-failures.log"
	return 1
}
export -f upload_one
export R2_BUCKET PREFIX WORK

: > "$WORK/upload-failures.log"
# `|| true` on both: xargs exits 123 when any invocation ultimately failed
# (a file that needed all 3 retries, say), and under `set -e` that would abort
# the whole script right here -- before the upload-failures.log check below
# ever runs -- turning a single flaky upload into a silent, unexplained exit.
# upload_one already records real failures to that log; let this block finish
# and let the check after it be what decides whether the run stops.
( cd "$WORK/apt-final" && find . -maxdepth 1 -name '*.deb' -printf '%f\n' \
	| xargs -P 12 -I{} bash -c 'upload_one "$@"' _ {} ) || true

( cd "$WORK/apt-final"
  upload_one Packages text/plain
  upload_one Packages.gz application/gzip
  upload_one Packages.xz application/x-xz
  upload_one Release text/plain ) || true

# A small fraction of uploads (consistently under 1%, different files each
# run) fail all 3 of upload_one's retries under 12-way concurrency but
# succeed immediately run serially -- contention for R2/wrangler connections,
# not a real problem with those files. One uncontended serial pass over just
# the failures is cheap and clears this reliably; only genuinely stop the run
# on a file that still fails after that.
if [ -s "$WORK/upload-failures.log" ]; then
	retry_list=$(awk '{print $2}' "$WORK/upload-failures.log")
	echo "   retrying $(echo "$retry_list" | wc -l) failed upload(s) serially (no contention) --" >&2
	: > "$WORK/upload-failures.log"
	( cd "$WORK/apt-final"
	  while read -r f; do
		[ -n "$f" ] || continue
		upload_one "$f"
	  done <<< "$retry_list" ) || true
fi

if [ -s "$WORK/upload-failures.log" ]; then
	echo "upload failures, aborting before this snapshot is trusted:" >&2
	cat "$WORK/upload-failures.log" >&2
	exit 1
fi
echo "   uploaded to $R2_DOMAIN/danos-apt/$REPO/snapshots/$TS/"

# _READY goes up now so build-iso-container.sh can use this snapshot; the
# provenance manifest (with the boot test result) follows in stage 6, once
# there is something to put in it. Both writes are to a path this run
# invented, so there is no stale-CDN risk from overwriting -- see the memory
# for why that matters and why every run gets a fresh timestamp.
: > "$WORK/READY_MARKER"
npx wrangler r2 object put "$R2_BUCKET/$PREFIX/_READY" --file "$WORK/READY_MARKER" \
	--content-type text/plain --remote > /dev/null 2>&1

# ---- stage 4: containerized ISO build (product variant) ----
echo "-- stage 4: containerized ISO build (product) --"
rm -rf "${WORK:?}/container-output-product"
BUILD_LOG="$WORK/iso-build-product.log"
( cd "$BUILD_ISO_DIR" && \
  DANOS_APT_URL="$R2_DOMAIN/danos-apt/$REPO/snapshots/$TS/" \
  OUTPUT="$WORK/container-output-product" \
  ISO_VARIANT=product \
  ./scripts/build-iso-container.sh > "$BUILD_LOG" 2>&1 ) \
  || { echo "ISO build (product) failed -- see $BUILD_LOG" >&2; tail -40 "$BUILD_LOG" >&2; exit 1; }

ISO=$(find "$WORK/container-output-product" -maxdepth 1 -name '*.hybrid.iso' | sort | tail -1)
[ -n "$ISO" ] && [ -f "$ISO" ] || { echo "no product ISO produced" >&2; exit 1; }
ISO_SHA256=$(sha256sum "$ISO" | awk '{print $1}')
echo "   product ISO: $(basename "$ISO")  sha256=$ISO_SHA256"

# ---- stage 4b: containerized ISO build (test variant) + package-set diff ----
# Closes item 1 of the 2026-09-28 project evaluation: product and test images
# built from the SAME immutable snapshot must carry an identical package set.
# The test overlay only drops config-file content into packages already
# selected -- it never adds or removes a package -- so any difference here
# means real drift, which is exactly what used to happen when the two
# variants were built minutes-to-days apart against a moving live Debian
# mirror (e.g. bind9 landing at different versions on each side; see
# danos-release-and-secureboot-flow). Building both back-to-back from one
# pinned snapshot in the same run doesn't just check for that drift, it
# removes the time gap that caused it.
echo "-- stage 4b: containerized ISO build (test) + package-set diff --"
rm -rf "${WORK:?}/container-output-test"
BUILD_LOG_TEST="$WORK/iso-build-test.log"
( cd "$BUILD_ISO_DIR" && \
  DANOS_APT_URL="$R2_DOMAIN/danos-apt/$REPO/snapshots/$TS/" \
  OUTPUT="$WORK/container-output-test" \
  ISO_VARIANT=test \
  ./scripts/build-iso-container.sh > "$BUILD_LOG_TEST" 2>&1 ) \
  || { echo "ISO build (test) failed -- see $BUILD_LOG_TEST" >&2; tail -40 "$BUILD_LOG_TEST" >&2; exit 1; }

TEST_ISO=$(find "$WORK/container-output-test" -maxdepth 1 -name '*.hybrid.iso' | sort | tail -1)
[ -n "$TEST_ISO" ] && [ -f "$TEST_ISO" ] || { echo "no test ISO produced" >&2; exit 1; }
echo "   test ISO: $(basename "$TEST_ISO")"

product_packages=$(find "$WORK/container-output-product" -maxdepth 1 -name '*.packages' | sort | tail -1)
test_packages=$(find "$WORK/container-output-test" -maxdepth 1 -name '*.packages' | sort | tail -1)
[ -n "$product_packages" ] && [ -n "$test_packages" ] || { echo "missing .packages manifest for diff" >&2; exit 1; }

if ! diff -u <(sort "$product_packages") <(sort "$test_packages") > "$WORK/product-test-package-diff.txt"; then
	echo "product/test package sets differ -- this should be impossible, the overlay never touches packages:" >&2
	cat "$WORK/product-test-package-diff.txt" >&2
	exit 1
fi
echo "   product and test package sets are identical ($(wc -l < "$product_packages") packages)"

# ---- stage 5: QEMU boot acceptance ----
echo "-- stage 5: QEMU boot acceptance --"
# boot-vm.sh's live-boot mode looks for vmlinuz/initrd.img at
# $(dirname ISO)/binary/live -- a sibling of the ISO itself, not of some other
# work directory -- so the extracted tree has to land there, not under $WORK.
ISO_DIR=$(cd "$(dirname "$ISO")" && pwd)
BOOT_LIVE="$WORK/boot-live"
# xorriso extracts the ISO9660 tree's own read-only permissions (dr-xr-xr-x),
# so a leftover extraction from a prior run blocks a plain rm -rf with
# "Permission denied" -- unlink needs write on the parent dir, which xorriso
# never grants. chmod it writable first.
chmod -R u+w "$BOOT_LIVE" 2>/dev/null || true
rm -rf "${BOOT_LIVE:?}" "${ISO_DIR:?}/binary"
xorriso -osirrox on -indev "$ISO" -extract /live "$BOOT_LIVE" > /dev/null 2>&1
mkdir -p "$ISO_DIR/binary"
ln -sf "$BOOT_LIVE" "$ISO_DIR/binary/live"

RUN="$OBS_DIR/run/close-the-loop"
rm -rf "${RUN:?}"
mkdir -p "$RUN"
BOOT_LOG="$WORK/boot.log"
bash "$SRC/toolkit/vm/boot-vm.sh" "$ISO" close-the-loop 12222 4096 > "$BOOT_LOG" 2>&1 &
BOOT_PID=$!
wait "$BOOT_PID" || true
# boot-vm.sh backgrounds qemu itself and returns almost immediately; RUN
# follows its own naming convention (OBS_DIR/run/<name>), which is simpler and
# more robust than parsing its stdout for a path it does not actually print.
RUN="$OBS_DIR/run/close-the-loop"
grep -q "console socket up" "$BOOT_LOG" || { echo "qemu did not start -- see $BOOT_LOG" >&2; cat "$BOOT_LOG" >&2; exit 1; }

# boot-vm.sh only opens the console socket; nothing writes console.log unless
# something connects and captures it. socat does that here -- but the QEMU
# serial backend serves exactly one client, so this has to be killed before
# console.py connects below, or console.py's login blocks until it times out
# ("LOGIN FAILED: timed out") with no indication the socket was the problem.
socat -u UNIX-CONNECT:"$RUN/console.sock" - > "$RUN/console.log" 2>/dev/null &
SOCAT_PID=$!

boot_pass=false
boot_output=""
for attempt in $(seq 1 30); do
	sleep 5
	if grep -q "login:" "$RUN/console.log" 2>/dev/null; then
		boot_pass=true
		break
	fi
	if grep -qiE "kernel panic|Emergency Mode" "$RUN/console.log" 2>/dev/null; then
		break
	fi
done
kill "$SOCAT_PID" 2>/dev/null || true
wait "$SOCAT_PID" 2>/dev/null || true

acceptance_pass=false
if $boot_pass; then
	# tr -d '\r': the serial console emits CRLF line endings, and a raw \r
	# left at the start of "Version:"'s line makes ^Version: never match --
	# the line literally begins with \r, not V. Confirmed by hand: the
	# transcript looks completely normal to a human, cat -A shows why grep
	# disagreed.
	boot_output=$(timeout 100 python3 "$SRC/toolkit/vm/console.py" "$RUN/console.sock" tmpuser tmppwd \
		"show version | cat" "show interfaces | cat" 2>&1 | tr -d '\r') || true
	echo "$boot_output" > "$WORK/boot-console-transcript.log"
	if echo "$boot_output" | grep -q "^Version:" && echo "$boot_output" | grep -qE '^dp[0-9a-z]+ '; then
		acceptance_pass=true
	fi
fi

# Always tear the VM down, pass or fail.
if [ -f "$RUN/qemu.pid" ]; then
	qpid=$(cat "$RUN/qemu.pid")
	kill "$qpid" 2>/dev/null || true
	while kill -0 "$qpid" 2>/dev/null; do sleep 1; done
fi
rm -f "${RUN:?}"/*.sock 2>/dev/null || true

if ! $acceptance_pass; then
	echo "QEMU acceptance FAILED (boot_pass=$boot_pass) -- see $WORK/boot.log and $WORK/boot-console-transcript.log" >&2
	exit 1
fi
reported_version=$(echo "$boot_output" | awk -F': *' '/^Version:/{print $2; exit}')
echo "   booted, logged in, show version reports $reported_version, dataplane interfaces present"

# ---- stage 6: provenance archive ----
echo "-- stage 6: provenance archive --"
BUILD_ISO_COMMIT=$(git -C "$BUILD_ISO_DIR" rev-parse HEAD)
python3 - "$WORK/obs-manifest.json" "$TS" "$(basename "$ISO")" "$ISO_SHA256" \
  "$BUILD_ISO_COMMIT" "$reported_version" "$deb_count" > "$WORK/provenance.json" <<'PYEOF'
import json, sys, datetime

manifest_path, ts, iso_name, iso_sha256, build_iso_commit, reported_version, deb_count = sys.argv[1:8]
manifest = json.load(open(manifest_path))

provenance = {
    "generated_at": datetime.datetime.now(datetime.UTC).isoformat(),
    "snapshot_timestamp": ts,
    "obs_project": "home:i-danos",
    "obs_repository": "2608",
    "obs_architecture": "x86_64",
    "obs_state": manifest["obs_state"],
    "obs_succeeded_count": manifest["succeeded_count"],
    "obs_succeeded_packages": manifest["succeeded"],
    "obs_disabled_packages": manifest["disabled"],
    "deb_file_count": int(deb_count),
    "build_iso_repo_commit": build_iso_commit,
    "iso_filename": iso_name,
    "iso_sha256": iso_sha256,
    "qemu_boot_acceptance": {
        "passed": True,
        "reported_version": reported_version,
        "checks": ["reached ttyS0 login prompt", "tmpuser login succeeded",
                   "'show version' returned a Version: line",
                   "'show interfaces' listed at least one dp* dataplane interface"],
    },
}
print(json.dumps(provenance, indent=2))
PYEOF

npx wrangler r2 object put "$R2_BUCKET/$PREFIX/provenance.json" --file "$WORK/provenance.json" \
	--content-type application/json --remote > /dev/null 2>&1
echo "   provenance archived to $R2_DOMAIN/danos-apt/$REPO/snapshots/$TS/provenance.json"

# ---- stage 7: formal release assembly ----
# mk-release.py builds the audited P0.5 release directory (sbom.json,
# source-revision-map.json, build-inputs.json, verification-summary.json)
# from the ISO's own manifest plus this run's own apt-final mirror --
# --obs-repo points at $WORK/apt-final rather than mk-release.py's default
# path, since this run's mirror never lands there. Only reached once QEMU
# acceptance has already passed, so a formal release directory is never
# assembled for an ISO that failed to boot.
echo "-- stage 7: formal release assembly --"
RELEASE_OUT=$(python3 "$SRC/toolkit/release/mk-release.py" "$ISO" \
	--obs-repo "$WORK/apt-final" --sources "$SRC" --obs-dir "$OBS_DIR")
echo "$RELEASE_OUT" | sed 's/^/   /'
RELEASE_DIR=$(echo "$RELEASE_OUT" | grep '^== ' | sed 's/^== //; s/ ==$//') || true

echo "== close-the-loop: PASS =="
echo "   snapshot:   $R2_DOMAIN/danos-apt/$REPO/snapshots/$TS/"
echo "   iso:        $ISO"
echo "   sha256:     $ISO_SHA256"
echo "   version:    $reported_version"
echo "   release:    $RELEASE_DIR"
