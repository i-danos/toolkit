#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-only
"""Build the transactions.json that judge-drift-event-correlation-broker-dp-transactions.py reads, from three read-only inputs.

The data plane logs nothing when it FINISHES programming a delivered route, so there is no completion record to read. What it does
offer is `dpa object show route`: every entry of its own route table, with the answer the forwarding backend gave when the entry
was made (state/backend). An entry that is listed has been inserted. This tool turns that into a completion record, and says
exactly how much it knows:

  delivery   the data plane's own netlink line "ROUTE: RTM_NEWROUTE table T ... dst P ..." (journal, needs `debug nl_route`),
             stamped with the journal's __REALTIME_TIMESTAMP. The line is written BEFORE the route is installed (src/ip_netlink.c,
             DP_DEBUG_W_VRF ahead of handle_route()), so installation cannot be earlier than this stamp.
  completion the END of the first `dpa object show route` snapshot that lists the route. Installation happened before that
             snapshot finished walking, so this is an UPPER bound on the completion time, not the instant. The snapshot before it
             that did not list the route is reported (last_absent_end) so the uncertainty window is visible.
  result     "ok" if the entry's state is in --ok-states (default full,not_needed,no_support), otherwise the state's own name.
             On a software-only data plane the backend answers no_support/not_needed for every route and never "full"; with
             --ok-states full such a capture does not pass. That is a property of the platform, not a defect of this tool.

All three inputs must come from ONE clock (the guest's CLOCK_REALTIME): snaps.log holds `date +%s.%N` before and after each
`dpa object show route`; the journal stamp is the same clock in microseconds.

Which deliveries count: only lines stamped inside the capture window (first snapshot start .. last snapshot end). The journal keeps
older runs' lines, and the same prefix delivered in an earlier run must not be matched with this run's installation; such lines
are listed under ignored_deliveries with the reason. A delivery also needs a snapshot that ENDED before it (the witness that the
route was not there yet); without one there is no completion record, because a new installation cannot be told from an old one.

Limits, by construction: a route installed and removed between two snapshots is never seen; resolution is one snapshot (here a few
ms); two deliveries for the SAME prefix are indistinguishable (one key); a delivery whose installation was deferred
(incomplete_route_add_nl) gets no completion at all, which is the correct answer. DELROUTE lines are listed under "ignored".

Usage: dpa-broker-dp-correlate.py --nl nl.jsonl --snaps DIR [--ok-states a,b] [--out transactions.json]
  DIR holds snaps.log ("<n> <start> <end> <rc>") and snap-<n>.json (the raw `dpa object show route` output).
Exit 0 always when the inputs are readable (a missing completion is data, not an error); 2 on unreadable input.
"""
import argparse
import json
import re
import sys
from pathlib import Path

LINE = re.compile(r"^ROUTE: (?P<verb>RTM_NEWROUTE|RTM_DELROUTE) table (?P<table>\d+) type (?P<type>\S+) dst (?P<prefix>\S+) "
                  r"gw (?P<gw>\S+) dev (?P<dev>\d+) scope (?P<scope>\d+) proto (?P<proto>\d+)")
DEFAULT_OK = ("full", "not_needed", "no_support")


def read_deliveries(path):
    out, ignored = [], []
    for ln in Path(path).read_text().splitlines():
        try:
            row = json.loads(ln)
        except json.JSONDecodeError:
            continue
        m = LINE.match(row.get("MESSAGE", ""))
        if not m or "__REALTIME_TIMESTAMP" not in row:
            continue
        rec = {"verb": m["verb"], "table": m["table"], "scope": m["scope"], "prefix": m["prefix"],
               "timestamp": int(row["__REALTIME_TIMESTAMP"]) / 1e6, "line": row["MESSAGE"].strip(),
               "pid": row.get("_PID"), "source": "journalctl -u vyatta-dataplane -o json __REALTIME_TIMESTAMP"}
        (out if m["verb"] == "RTM_NEWROUTE" else ignored).append(rec)
    out.sort(key=lambda r: r["timestamp"])
    return out, ignored


def read_snapshots(d):
    d = Path(d)
    snaps, skipped = [], []
    for ln in (d / "snaps.log").read_text().splitlines():
        f = ln.split()
        if len(f) != 4:
            continue
        n, start, end, rc = int(f[0]), float(f[1]), float(f[2]), int(f[3])
        try:
            if rc != 0:
                raise ValueError("rc %d" % rc)
            objs = json.loads((d / ("snap-%d.json" % n)).read_text())["dpa_objects"]["objects"]
        except (OSError, ValueError, KeyError) as e:
            skipped.append({"snapshot": n, "why": str(e)[:80]})
            continue
        snaps.append({"n": n, "file": "snap-%d.json" % n, "start": start, "end": end,
                      "routes": {o["key"]: o for o in objs if o.get("class") == "route"}})
    snaps.sort(key=lambda s: s["start"])
    return snaps, skipped


def find_key(snap, table, prefix, scope):
    want = "/table:%s/%s/scope:%s" % (table, prefix, scope)
    for k, o in snap["routes"].items():
        if k.endswith(want):
            return k, o
    return None, None


def correlate(deliveries, snaps, ok_states):
    tx = []
    for dl in deliveries:
        first = None
        last_absent_end = None
        if not any(s["end"] <= dl["timestamp"] for s in snaps):
            tx.append({"prefix": dl["prefix"], "delivery": {kk: dl[kk] for kk in ("timestamp", "line", "pid", "source")}, "completion": None,
                       "note": "no snapshot ended before this delivery, so nothing shows the route was absent first"})
            continue
        for s in snaps:
            k, o = find_key(s, dl["table"], dl["prefix"], dl["scope"])
            if o is not None:
                first = (s, k, o)
                break
            last_absent_end = s["end"]
        rec = {"prefix": dl["prefix"], "delivery": {kk: dl[kk] for kk in ("timestamp", "line", "pid", "source")}, "completion": None}
        if first is None:
            rec["note"] = "no snapshot lists this route: delivered but never seen installed (deferred/incomplete, or removed between polls)"
        else:
            s, k, o = first
            rec["completion"] = {
                "timestamp": s["end"], "result": "ok" if o.get("state") in ok_states else o.get("state", "unknown"),
                "state": o.get("state"), "backend": o.get("backend"), "key": k, "snapshot": s["file"],
                "snapshot_start": s["start"], "snapshot_end": s["end"], "last_absent_end": last_absent_end,
                "basis": "end of the first dpa object show route snapshot that lists the route (upper bound of the completion time)",
                "uncertainty_seconds": (s["end"] - last_absent_end) if last_absent_end is not None else None}
        tx.append(rec)
    return tx


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--nl", required=True)
    ap.add_argument("--snaps", required=True)
    ap.add_argument("--ok-states", default=",".join(DEFAULT_OK))
    ap.add_argument("--out")
    a = ap.parse_args()
    try:
        deliveries, ignored = read_deliveries(a.nl)
        snaps, skipped = read_snapshots(a.snaps)
    except OSError as e:
        print("unreadable input: %s" % e, file=sys.stderr)
        return 2
    ok = tuple(x for x in a.ok_states.split(",") if x)
    outside = []
    if snaps:
        lo, hi = min(s["start"] for s in snaps), max(s["end"] for s in snaps)
        inside = [d for d in deliveries if lo <= d["timestamp"] <= hi]
        outside = [dict(d, why="stamped outside the capture window %.6f..%.6f (an earlier run's line, or the data plane before polling began)" % (lo, hi))
                   for d in deliveries if not (lo <= d["timestamp"] <= hi)]
        deliveries = inside
    doc = {"transactions": correlate(deliveries, snaps, ok),
           "method": {"ok_states": list(ok), "snapshots_used": len(snaps), "snapshots_skipped": skipped,
                      "ignored_deliveries": [{"verb": i["verb"], "prefix": i["prefix"], "timestamp": i["timestamp"]} for i in ignored]
                      + [{"verb": o["verb"], "prefix": o["prefix"], "timestamp": o["timestamp"], "why": o["why"]} for o in outside]}}
    text = json.dumps(doc, indent=1) + "\n"
    if a.out:
        Path(a.out).write_text(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
