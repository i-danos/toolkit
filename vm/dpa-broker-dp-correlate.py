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

COMPLETION RECORDS (vyatta-dataplane >= 3.14.46). The data plane now writes one line when it has finished programming a route:

  ROUTE: programmed cls=route op=add vrf=1 table=254 prefix=P scope=0 result=ok sw_state=full state=S backend=B mono_ns=N wall_ns=N

With --completions FILE (the same journal, `grep 'ROUTE: programmed'`, -o json) the completion of a delivery is that line itself: the
first unused record with the same table/prefix/scope, op=add, from the same pid, stamped at or after the delivery. Its journal stamp
(_SOURCE_REALTIME_TIMESTAMP, else __REALTIME_TIMESTAMP) is on the same clock as the delivery's, so the order and the gap are measured, not bounded by a poll. `result` is the record's own
word (ok / not_needed / error), not a mapping of the backend state, so --ok-states plays no part in this mode and the strict and the
default reading cannot differ. A delivery with no matching record gets completion null (deferred, failed before the record, or the
data plane predates 3.14.46). --snaps is then optional: given, it supplies the capture window and each transaction also carries the
polled upper bound for comparison; absent, every delivery in --nl is used.

Usage: dpa-broker-dp-correlate.py --nl nl.jsonl [--completions completion.jsonl] [--snaps DIR] [--ok-states a,b] [--out transactions.json]
  (--snaps is required unless --completions is given)
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


def stamp(row):
    """(seconds, field) of a journal row. _SOURCE_REALTIME_TIMESTAMP is when the syslog datagram reached the journal socket, i.e. when
    the data plane wrote the line; __REALTIME_TIMESTAMP is when journald got round to it (measured here ~2 ms later and jittery), so the
    source stamp is preferred and __REALTIME_TIMESTAMP is the fallback for rows that lack it. Same CLOCK_REALTIME either way."""
    for f in ("_SOURCE_REALTIME_TIMESTAMP", "__REALTIME_TIMESTAMP"):
        if f in row:
            return int(row[f]) / 1e6, f
    return None, None


def read_deliveries(path):
    out, ignored = [], []
    for ln in Path(path).read_text().splitlines():
        try:
            row = json.loads(ln)
        except json.JSONDecodeError:
            continue
        m = LINE.match(row.get("MESSAGE", ""))
        ts, field = stamp(row)
        if not m or ts is None:
            continue
        rec = {"verb": m["verb"], "table": m["table"], "scope": m["scope"], "prefix": m["prefix"],
               "timestamp": ts, "line": row["MESSAGE"].strip(),
               "pid": row.get("_PID"), "source": "journalctl -u vyatta-dataplane -o json " + field}
        (out if m["verb"] == "RTM_NEWROUTE" else ignored).append(rec)
    out.sort(key=lambda r: r["timestamp"])
    return out, ignored


PROG = re.compile(r"^ROUTE: programmed (?P<kv>(?:\S+=\S+ ?)+)$")


def read_completions(path):
    out = []
    for ln in Path(path).read_text().splitlines():
        try:
            row = json.loads(ln)
        except json.JSONDecodeError:
            continue
        m = PROG.match(row.get("MESSAGE", "").strip())
        ts, field = stamp(row)
        if not m or ts is None:
            continue
        kv = dict(p.split("=", 1) for p in m["kv"].split())
        kv.update(timestamp=ts, stamp_field=field, line=row["MESSAGE"].strip(), pid=row.get("_PID"))
        out.append(kv)
    out.sort(key=lambda r: r["timestamp"])
    return out


def match_completions(deliveries, comps):
    """Pair each delivery with the first unused completion record for the same route. Returns (transactions, unmatched records)."""
    used, tx = set(), []
    for dl in deliveries:
        rec = {"prefix": dl["prefix"], "delivery": {kk: dl[kk] for kk in ("timestamp", "line", "pid", "source")}, "completion": None}
        for i, c in enumerate(comps):
            if i in used or c.get("op") != "add" or c.get("cls") != "route" or c["timestamp"] < dl["timestamp"]:
                continue
            if (c.get("table"), c.get("prefix"), c.get("scope"), c["pid"]) != (dl["table"], dl["prefix"], dl["scope"], dl["pid"]):
                continue
            used.add(i)
            rec["completion"] = {
                "timestamp": c["timestamp"], "result": c.get("result", "unknown"), "state": c.get("state"), "sw_state": c.get("sw_state"),
                "backend": c.get("backend"), "op": c["op"], "mono_ns": int(c["mono_ns"]), "wall_ns": int(c["wall_ns"]), "line": c["line"],
                "pid": c["pid"], "lag_seconds": c["timestamp"] - dl["timestamp"],
                "source": "journalctl -u vyatta-dataplane -o json " + c["stamp_field"],
                "basis": "the data plane's own 'programmed' record, written after lpm_add() and the forwarding-backend step (measured, not polled)"}
            break
        if rec["completion"] is None:
            rec["note"] = "no 'programmed' record followed this delivery: deferred, failed before the record, or a data plane older than 3.14.46"
        tx.append(rec)
    return tx, [c for i, c in enumerate(comps) if i not in used]


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
    ap.add_argument("--snaps")
    ap.add_argument("--completions", help="journal -o json lines containing 'ROUTE: programmed' (data plane >= 3.14.46)")
    ap.add_argument("--ok-states", default=",".join(DEFAULT_OK))
    ap.add_argument("--out")
    a = ap.parse_args()
    if not a.snaps and not a.completions:
        ap.error("--snaps is required unless --completions is given")
    try:
        deliveries, ignored = read_deliveries(a.nl)
        snaps, skipped = read_snapshots(a.snaps) if a.snaps else ([], [])
        comps = read_completions(a.completions) if a.completions else None
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
    unmatched = []
    if comps is not None:
        txs, unmatched = match_completions(deliveries, comps)
        if snaps:  # keep the old polled bound next to the measured completion, for comparison only
            for t, p in zip(txs, correlate(deliveries, snaps, ok)):
                if p.get("completion"):
                    t["polled_upper_bound"] = {"timestamp": p["completion"]["timestamp"], "uncertainty_seconds": p["completion"]["uncertainty_seconds"]}
    else:
        txs = correlate(deliveries, snaps, ok)
    doc = {"transactions": txs,
           "method": {"completion_source": "programmed-records" if comps is not None else "polled-snapshots",
                      "unmatched_completion_records": [{"prefix": u.get("prefix"), "op": u.get("op"), "timestamp": u["timestamp"]} for u in unmatched],
                      "ok_states": list(ok) if comps is None else "unused (result comes from the record)", "snapshots_used": len(snaps), "snapshots_skipped": skipped,
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
