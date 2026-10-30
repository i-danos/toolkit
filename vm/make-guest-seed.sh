#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-only
# Build a NoCloud seed ISO that runs ONE verify-case.py case INSIDE the guest, from cloud-init.
#
#   make-guest-seed.sh CASE.yaml OUT.iso [--var K=V]... [--instance-id ID] [--no-validate]
#
# Why: the f6 / p2p4 cases pin their execution context (root, cgroup cloud-final.service) because
# `set` has only ever been accepted from there. A serial-console login is a different context
# (serial-getty@ttyS0.service), so those cases cannot be run with --console; this seed runs the
# UNMODIFIED runner with `--exec local` from runcmd instead and prints the JUnit file on the serial
# port between fixed markers. The seed is independent of the ISO under test.
#
# Serial output (all lines start with the fixed text shown; see README "Three ways to run a case"):
# The serial port is written with a fresh open() per write and only from run.sh itself; the runner's own
# stdout/stderr and everything else go to files under /vm/out (run.log, stdout.log, stderr.log, junit.xml,
# result-block.txt). Why: serial-getty@.service has TTYVHangup=yes, so when agetty starts AFTER a script has
# opened /dev/ttyS0 (the usual "exec >/dev/ttyS0"), vhangup(2) revokes that descriptor, every later write fails
# with EIO, the output is lost and the script exits non-zero, which cloud-init reports as "Failed to run module
# scripts-user". The runner still ran; only the report was lost (handoff/runs/f6-hang-r2).
# VC_MODE (set in the guest's environment): setsid (default; same cgroup, so f6's execution-context step still
# passes) | plain | systemd-run (CONTROL ONLY: the case runs in vc-case.service, a different cgroup, so the
# execution-context step FAILS). VC_TTY / VC_TTY_TRIES / VC_TTY_PAUSE exist for the tests.
#   === VC-SEED BEGIN case=<id> ===
#   VC-SEED-SHA256 runner=<hex> console=<hex> case=<hex>        what was run, for after-the-fact checks
#   ... the runner's own PASS/FAIL/SKIP lines ...
#   VC-SEED-RC=<runner exit status>
#   VC-SEED-JUNIT-SHA256=<hex> SIZE=<bytes>
#   JUNIT_BEGIN  /  <gzip+base64 of the JUnit XML, 76 columns>  /  JUNIT_END
#   === VC-SEED END ===
# Decode: sed -n '/^JUNIT_BEGIN/,/^JUNIT_END/p' serial.log | sed '1d;$d' | tr -d '\r' | base64 -d | gunzip
# and compare with VC-SEED-JUNIT-SHA256. No evidence document is written in the guest (no ISO hash, no
# repository there); sign/derive that on the host from the extracted JUnit.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$HERE/verify-case.py"
CONSOLE="$HERE/console.py"

die() { echo "make-guest-seed: $*" >&2; exit 2; }
usage() { sed -n '4,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[ $# -ge 2 ] || usage
CASE="$1"; OUT="$2"; shift 2
VARS=(); IID=""; VALIDATE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --var)         [ $# -ge 2 ] || die "--var needs K=V"
                   case "$2" in [A-Za-z_]*=*) ;; *) die "--var wants K=V, got '$2'";; esac
                   case "$2" in *[\'\"\\\$\`]*|*$'\n'*) die "--var value may not contain quotes, backslash, \$, backtick or newline: '$2'";; esac
                   VARS+=("$2"); shift 2;;
    --instance-id) [ $# -ge 2 ] || die "--instance-id needs a value"
                   case "$2" in *[!A-Za-z0-9._-]*|"") die "--instance-id may only contain A-Za-z0-9._-";; esac
                   IID="$2"; shift 2;;
    --no-validate) VALIDATE=0; shift;;
    *)             die "unknown argument '$1'";;
  esac
done

[ -f "$CASE" ]   || die "case file not found: $CASE"
[ -f "$RUNNER" ] || die "runner not found: $RUNNER"
[ -f "$CONSOLE" ] || die "console.py not found: $CONSOLE"
case "$OUT" in *.iso) ;; *) die "output must end in .iso: $OUT";; esac
[ ! -e "$OUT" ] || die "refusing to overwrite existing $OUT"
[ -d "$(dirname "$OUT")" ] || die "output directory does not exist: $(dirname "$OUT")"
if command -v genisoimage >/dev/null; then MKISO=genisoimage
elif command -v xorriso >/dev/null; then MKISO="xorriso -as mkisofs"
else die "neither genisoimage nor xorriso found (tried both); install one of them"; fi
command -v python3 >/dev/null || die "python3 not found"

if [ "$VALIDATE" = 1 ]; then
  VA=(); for v in "${VARS[@]}"; do VA+=(--var "$v"); done
  python3 -I "$RUNNER" --validate "${VA[@]}" "$CASE" >/dev/null || die "the case does not validate; no seed built"
fi

CASE_ID="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$CASE" 2>/dev/null)" \
  || die "cannot read the case id from $CASE"
case "$CASE_ID" in *[!A-Za-z0-9._-]*|"") die "case id '$CASE_ID' has characters not allowed in a seed";; esac

sha() { sha256sum "$1" | cut -d' ' -f1; }
R_SHA="$(sha "$RUNNER")"; C_SHA="$(sha "$CONSOLE")"; K_SHA="$(sha "$CASE")"
[ -n "$IID" ] || IID="danos-vc-${CASE_ID}-${K_SHA:0:12}"

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
VARARGS=""
for v in "${VARS[@]}"; do VARARGS+=" --var '$v'"; done

cat > "$STAGE/run.sh" <<EOF
#!/bin/bash
# Hang-up-resistant wrapper. The runner, console.py and the case are the UNMODIFIED files.
# Why it differs from the stock run.sh: stock does "exec >/dev/ttyS0". serial-getty@.service has
# TTYVHangup=yes, so when systemd starts agetty AFTER that open, vhangup(2) revokes the descriptor and every
# later write fails with EIO -- the runner still runs, but its output is lost and the last write makes
# cloud-init report "Failed to run module scripts-user". Here: output goes to files first, the serial port is
# opened afresh for every write, and a result block is written to the port only after the runner has ended.
# VC_MODE: setsid (default; keeps the cgroup, so the execution-context step still passes) | plain |
#          systemd-run (CONTROL ONLY: new cgroup vc-case.service, the f6 execution-context step will fail)
OUT=/vm/out; LOG=\$OUT/run.log; TTY=\${VC_TTY:-/dev/ttyS0}; MODE=\${VC_MODE:-setsid}
TRIES=\${VC_TTY_TRIES:-8}; PAUSE=\${VC_TTY_PAUSE:-1}
mkdir -p \$OUT
t() { printf '[%s up=%s] %s\\n' "\$(date -u +%T)" "\$(cut -d' ' -f1 /proc/uptime)" "\$*" >> \$LOG; }
# one write = one open(); retried because the port can be mid-reset when the getty starts
tw() { local n; for ((n = 0; n < TRIES; n++)); do if printf '%s\\n' "\$*" >> \$TTY 2>/dev/null; then return 0; fi; sleep \$PAUSE; done; t "TTY-WRITE-FAILED: \${1:0:70}"; return 1; }
emit() { local n; for ((n = 0; n < TRIES; n++)); do if cat "\$1" >> \$TTY 2>/dev/null; then return 0; fi; sleep \$PAUSE; done; t "TTY-EMIT-FAILED: \$1"; return 1; }
# probes: which signal (if any) arrived
for s in HUP TERM INT QUIT PIPE; do trap "t 'SIGNAL \$s received'; echo \$s >> \$OUT/signals.log" \$s; done
echo \$\$ > /run/vc.pid 2>/dev/null || echo \$\$ > \$OUT/vc.pid
# the descriptor stock run.sh would have used, kept ONLY to measure it: fd 3 is opened now and never written to
exec 3>>\$TTY 2>/dev/null || t "fd3 open failed"
exec >> \$LOG 2>&1
t "start pid=\$\$ ppid=\$PPID mode=\$MODE uid=\$(id -u) cgroup=\$(tr '\\n' ' ' </proc/\$\$/cgroup)"
t "agetty at start: \$(systemctl show serial-getty@ttyS0 -p ExecMainStartTimestampMonotonic -p NRestarts -p ActiveState 2>&1 | tr '\\n' ' ')"
tw "=== VC-SEED BEGIN case=$CASE_ID ==="
tw "VC-SEED-SHA256 runner=\$(sha256sum /vm/verify-case.py | cut -d' ' -f1) console=\$(sha256sum /vm/console.py | cut -d' ' -f1) case=\$(sha256sum /vm/case.yaml | cut -d' ' -f1)"
tw "VC-SEED-EXPECTED runner=$R_SHA console=$C_SHA case=$K_SHA"
( while :; do
    old=\$(stty -a <&3 2>&1 >/dev/null | head -c 40); [ -n "\$old" ] || old=ok          # the stock descriptor
    new=\$(stty -F \$TTY -a 2>&1 >/dev/null | head -c 40); [ -n "\$new" ] || new=ok     # a fresh open
    t "hb runner=\$(pgrep -f 'python3 /vm/verify-case.py' | head -1) stock-fd=\$old fresh-open=\$new configd=\$(systemctl is-active configd 2>&1) acmd=\$(systemctl is-active acmd 2>&1) agetty-start=\$(systemctl show serial-getty@ttyS0 -p ExecMainStartTimestampMonotonic --value 2>&1)"
    sleep 5
  done ) &
HB=\$!
RUN=(python3 /vm/verify-case.py /vm/case.yaml --exec local --junit \$OUT/junit.xml$VARARGS)
case "\$MODE" in
  systemd-run) systemd-run --unit=vc-case --collect --wait --pipe --property=SendSIGHUP=no "\${RUN[@]}" > \$OUT/stdout.log 2> \$OUT/stderr.log ;;
  plain)       "\${RUN[@]}" > \$OUT/stdout.log 2> \$OUT/stderr.log ;;
  *)           setsid -w "\${RUN[@]}" > \$OUT/stdout.log 2> \$OUT/stderr.log ;;
esac
rc=\$?
kill \$HB 2>/dev/null
t "runner exit rc=\$rc junit=\$(ls -l \$OUT/junit.xml 2>&1)"
t "agetty at end: \$(systemctl show serial-getty@ttyS0 -p ExecMainStartTimestampMonotonic -p NRestarts -p ActiveState 2>&1 | tr '\\n' ' ')"
{ cat \$OUT/stdout.log
  echo "VC-SEED-RC=\$rc"
  if [ -s \$OUT/junit.xml ]; then
    echo "VC-SEED-JUNIT-SHA256=\$(sha256sum \$OUT/junit.xml | cut -d' ' -f1) SIZE=\$(stat -c %s \$OUT/junit.xml)"
    echo JUNIT_BEGIN; gzip -9 < \$OUT/junit.xml | base64 -w 76; echo JUNIT_END
  else echo "VC-SEED-NO-JUNIT"; fi
  echo "=== VC-SEED END ==="; } > \$OUT/result-block.txt
emit \$OUT/result-block.txt && t "result block written to \$TTY" 
t "stock fd 3 at the end: \$(stty -a <&3 2>&1 >/dev/null | head -c 60)"
exit 0
EOF

python3 -I - "$STAGE" "$HERE" "$CASE" "$IID" "$CASE_ID" <<'PYEOF'
import base64, gzip, json, os, sys
stage, here, case, iid, cid = sys.argv[1:6]
def blob(path, dest, mode):
    data = open(path, "rb").read()
    return {"path": dest, "permissions": mode, "encoding": "gz+b64",
            "content": base64.b64encode(gzip.compress(data, 9, mtime=0)).decode()}
doc = {"hostname": "danos-ci-test",
       "write_files": [blob(os.path.join(here, "verify-case.py"), "/vm/verify-case.py", "0755"),
                       blob(os.path.join(here, "console.py"), "/vm/console.py", "0644"),
                       blob(case, "/vm/case.yaml", "0644"),
                       blob(os.path.join(stage, "run.sh"), "/vm/run.sh", "0755")],
       "runcmd": [["bash", "/vm/run.sh"]]}
# JSON is valid YAML; the first line makes cloud-init treat it as cloud-config
with open(os.path.join(stage, "user-data"), "w") as f:
    f.write("#cloud-config\n" + json.dumps(doc, indent=1) + "\n")
with open(os.path.join(stage, "meta-data"), "w") as f:
    f.write("instance-id: %s\nlocal-hostname: danos-ci-test\n" % iid)
PYEOF
[ $? -eq 0 ] || die "could not write user-data"

rm -f "$STAGE/run.sh"
$MKISO -quiet -output "$OUT" -volid cidata -joliet -rock "$STAGE/user-data" "$STAGE/meta-data" 2>"$STAGE/gen.err" \
  || { cat "$STAGE/gen.err" >&2; die "${MKISO%% *} failed"; }

echo "seed: $OUT  ($(stat -c %s "$OUT") bytes, volume label cidata, instance-id $IID)"
echo "runner   sha256 $R_SHA  $RUNNER"
echo "console  sha256 $C_SHA  $CONSOLE"
echo "case     sha256 $K_SHA  $CASE"
echo "seed.iso sha256 $(sha "$OUT")"
echo "contents of the seed ISO:"
if command -v xorriso >/dev/null; then
  xorriso -indev "$OUT" -find / -type f 2>/dev/null | grep -v '^$' | sed 's/^/  /'
fi
echo "files the guest will write (after decoding user-data), with sha256:"
python3 -I - "$OUT" <<'PYEOF'
import base64, gzip, hashlib, json, os, subprocess, sys, tempfile
iso = sys.argv[1]
ud = ""
with tempfile.TemporaryDirectory() as td:
    # xorriso has no -cat; extract the file instead. isoinfo (cdrkit) is the fallback.
    dst = os.path.join(td, "user-data")
    subprocess.run(["xorriso", "-osirrox", "on", "-indev", iso, "-extract", "/user-data", dst],
                   capture_output=True)
    if os.path.exists(dst):
        ud = open(dst).read()
if not ud.startswith("#cloud-config"):
    ud = subprocess.run(["isoinfo", "-R", "-i", iso, "-x", "/user-data"], capture_output=True).stdout.decode()
doc = json.loads(ud.split("\n", 1)[1])
for w in doc["write_files"]:
    data = gzip.decompress(base64.b64decode(w["content"]))
    print("  %s  %s  %s bytes  %s" % (hashlib.sha256(data).hexdigest(), w["path"], len(data), w["permissions"]))
print("  runcmd: %s" % doc["runcmd"])
PYEOF
