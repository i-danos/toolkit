#!/bin/bash
# How often does drift actually happen, with nobody injecting it?
#
# Both candidate answers to route repair -- a downstream FRR replay primitive
# and a DANOS-native reconciler -- are answers to a problem whose rate nobody
# has measured. The decision material says so in as many words, and this is the
# measurement that fills that hole.
#
# What it can and cannot claim, stated first because the number will outlive
# this comment:
#
#   This observes drift under the regression suite's load. That is not
#   production traffic and not a production configuration churn rate. What
#   comes out is a LOWER BOUND on how often drift occurs, from one workload,
#   on one box. It is not a representative rate and must not be quoted as one.
#
# Why a wrapper rather than dpa-drift.py --watch: the tool runs on the router,
# and the regression reboots the routers between topologies, so a watch started
# on the box dies with it. The observer therefore sits outside and calls the
# tool per cycle. The comparison itself is still the tool's -- the key
# construction, the ownership tri-state, the scope handling and the keyspace
# guard all live there and none of it is reimplemented here. This does the
# bookkeeping only.
#
# A router that cannot be read is counted separately and excluded from the
# denominator. An unreadable side looks exactly like an empty one, and a reboot
# would otherwise register as total drift -- which is the failure mode this
# whole line of work exists to avoid.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-/home/aikon/danos/.obs/measure-drift-rate.log}
NDJSON=${NDJSON:-/home/aikon/danos/.obs/measure-drift-rate.ndjson}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8"
R1=${R1:-192.168.203.155}
INTERVAL=${INTERVAL:-20}
DURATION=${DURATION:-0}          # seconds; 0 means "until stopped"
LABEL_FILE=${LABEL_FILE:-}       # optional: a file whose contents tag each cycle

exec > "$OUT" 2>&1
: > "$NDJSON"

# Every address a router can appear at across the topologies the regression
# runs: .155-.157 for the three-router suites, .231-.234 for BGP. The observer
# tries them in order and reports which one answered, so a cycle that finds no
# router is distinguishable from one that found a broken tool.
HOSTS=${HOSTS:-192.168.203.155,192.168.203.156,192.168.203.231,192.168.203.232}

TOOLB64=$(mktemp)
base64 -w0 "$HERE/dpa-drift.py" > "$TOOLB64"
trap 'rm -f "$TOOLB64"' EXIT

start=$(date +%s)
echo "=== observing every ${INTERVAL}s ==="
echo "    started $(date '+%F %T')"
echo

python3 - "$NDJSON" "$INTERVAL" "$DURATION" "$LABEL_FILE" "$HOSTS" "$TOOLB64" <<'PY'
import json, subprocess, sys, time

ndjson, interval, duration, label_file, candidates = sys.argv[1:6]
interval = float(interval); duration = float(duration)

def ssh(host, cmd, timeout=120):
    return subprocess.run(
        ["docker", "exec", "danos-robot", "timeout", "90", "sshpass", "-p", "vyatta",
         "ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
         "-o", "ConnectTimeout=8", "vyatta@" + host, cmd],
        capture_output=True, text=True, timeout=timeout)

# The routers run a live image with no persistent storage, so anything put in
# /tmp is gone the moment a suite reboots them -- which the regression does
# between topologies. The first version of this installed the tool once at the
# start and then recorded 210 unreadable cycles out of 211, while its summary
# line read "0.0% of observed": a denominator of one, presented as a clean
# result. So the tool is reinstalled whenever it is found missing.
TOOL_B64 = open(sys.argv[6]).read().strip()

def install(host):
    return ssh(host, "echo '%s' | base64 -d | sudo tee /tmp/dpa-drift.py >/dev/null"
                     " && sudo chmod 755 /tmp/dpa-drift.py && echo ok" % TOOL_B64,
               timeout=180).stdout.strip().endswith("ok")

# Not every topology has a router at the same address: the three-router suites
# use .155-.157 and BGP uses .231-.234. Watching one address means the BGP
# phase is unobservable, which is a limit on what this can measure and is
# reported rather than hidden.
CANDIDATES = [c for c in candidates.split(",") if c]

def read_drift():
    """Return (host, data) or (host_or_None, None). Distinguishes, in the
    record it writes, a router that is absent from a tool that is missing from
    a tool that failed -- three different reasons a cycle cannot be counted,
    and only the first is the regression legitimately moving on."""
    for host in CANDIDATES:
        p = ssh(host, "sudo python3 /tmp/dpa-drift.py --json 2>/dev/null")
        out = p.stdout.strip()
        if out:
            try:
                return host, json.loads(out.splitlines()[-1]), "ok"
            except (ValueError, IndexError):
                return host, None, "unparsable"
        probe = ssh(host, "echo alive", timeout=60).stdout.strip()
        if probe != "alive":
            continue                      # router not there; try the next
        if install(host):
            p = ssh(host, "sudo python3 /tmp/dpa-drift.py --json 2>/dev/null")
            out = p.stdout.strip()
            if out:
                try:
                    return host, json.loads(out.splitlines()[-1]), "reinstalled"
                except (ValueError, IndexError):
                    return host, None, "unparsable"
        return host, None, "tool-failed"
    return None, None, "no-router"

def label():
    if not label_file:
        return ""
    try:
        with open(label_file) as f:
            return f.read().strip()
    except OSError:
        return ""

# Persistence is counted here because the box-side watch cannot survive the
# reboots. A key's run length is how many CONSECUTIVE observed cycles it has
# been in disagreement; an unreadable cycle does not break a run, because the
# box being away is not evidence that the drift cleared.
runs = {}          # key -> current consecutive count
longest = {}       # key -> longest run ever seen
observed = 0
unreadable = 0
dirty_cycles = 0
cycle = 0
start = time.time()

out = open(ndjson, "a")
while duration == 0 or (time.time() - start) < duration:
    cycle += 1
    rec = {"cycle": cycle, "t": round(time.time() - start, 1), "label": label()}
    try:
        host, data, why = read_drift()
    except Exception as e:
        host, data, why = None, None, "error:%s" % type(e).__name__

    if data is None or "desired" not in data:
        unreadable += 1
        rec["state"] = "unreadable"
        rec["why"] = why
        rec["host"] = host
        out.write(json.dumps(rec) + "\n"); out.flush()
        time.sleep(interval)
        continue

    observed += 1
    missing = [tuple(k) if isinstance(k, list) else k
               for k in data.get("desired_not_programmed", [])]
    extra = [tuple(k) if isinstance(k, list) else k
             for k in data.get("programmed_not_desired", [])]
    keys = set(map(str, missing)) | set(map(str, extra))

    for k in list(runs):
        if k not in keys:
            del runs[k]
    for k in keys:
        runs[k] = runs.get(k, 0) + 1
        longest[k] = max(longest.get(k, 0), runs[k])

    if keys:
        dirty_cycles += 1
    rec.update({"state": "ok", "host": host, "why": why, "desired": data.get("desired"),
                "programmed": data.get("programmed"),
                "missing": len(missing), "extra": len(extra),
                "keyspace_mismatch": data.get("keyspace_mismatch"),
                "runs": {k: v for k, v in runs.items()}})
    out.write(json.dumps(rec) + "\n"); out.flush()
    time.sleep(interval)

print()
print("=== result ===")
print("    observed cycles      %d" % observed)
print("    unreadable cycles    %d  (excluded from the denominator)" % unreadable)
if observed:
    print("    cycles with drift    %d  (%.1f%% of observed)"
          % (dirty_cycles, 100.0 * dirty_cycles / observed))
else:
    print("    cycles with drift    -- nothing was observed")
print("    distinct keys seen   %d" % len(longest))
if longest:
    print()
    print("    persistence, longest consecutive observed cycles per key:")
    dist = {}
    for k, v in longest.items():
        dist[v] = dist.get(v, 0) + 1
    for n in sorted(dist):
        print("      %2d cycle(s): %d key(s)" % (n, dist[n]))
    print()
    print("    A run of 1 is a route in flight, not drift: the path is")
    print("    asynchronous and every probe here sleeps before reading for")
    print("    that reason. A threshold, if one is ever chosen, is chosen")
    print("    from this distribution.")
PY

echo
echo "    finished $(date '+%F %T'), $(( $(date +%s) - start ))s elapsed"
echo "    per-cycle records: $NDJSON"
echo
echo "    This is a lower bound from the regression workload on one box. It is"
echo "    not a production drift rate and must not be quoted as one."
